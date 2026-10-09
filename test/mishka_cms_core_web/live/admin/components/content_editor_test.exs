defmodule MishkaCmsCoreWeb.Test.ContentEditorTest do
  @moduledoc """
  The content editor a `:textarea` field with `extra %{content_editor: true}` draws through
  `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1`, and its server half,
  `MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker`: the markup the hook mounts on,
  and every answer the hook asks for — the content split into blocks, a component built from the
  palette, a placed one's settings, and the previews pushed after.

  The editor is drawn here by a LiveView of its own, with the assigns a Gervaz form hands its
  adapter, so it is the adapter and the component under test and not one resource's form. The hook
  side is the CMS's `assets/js/content_editor.test.js`.

  `async: false` — `SiteState`, compiled modules, the event registry and the atom table are
  process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.{ContentComponents, Translations}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Test.Plugins.{ContentEditorBlocks, ContentEditorPalette}
  alias MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker

  @moduletag :integration

  @endpoint MishkaCmsCore.TestEndpoint
  @await 5_000

  @editor "post_form-form_content-editor"
  @components "#post_form-form_content-editor-components"
  @picker "post_form-form_content-editor-components"

  defmodule Host do
    use Phoenix.LiveView

    import MishkaGervaz.Helpers, only: [dynamic_component: 1]

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         user: session["user"],
         value: session["value"],
         forms: session["forms"] || ["post_form"],
         extra: session["extra"] || %{content_editor: true},
         placeholder: Map.get(session, "placeholder", "Write the post"),
         module: session["module"] || MishkaCmsCoreWeb.UIAdapters.Admin,
         debounce: Map.get(session, "debounce", 300)
       )}
    end

    def render(assigns) do
      ~H"""
      <div id="host">
        <.dynamic_component
          :for={form <- @forms}
          module={@module}
          function={:textarea}
          name="form[content]"
          id={form <> "-form_content"}
          table_id={form}
          value={@value}
          extra={@extra}
          state={%{master_user?: false, current_user: @user, field_values: %{}, form: nil}}
          placeholder={@placeholder}
          rows={8}
          disabled={false}
          readonly={false}
          label_id={form <> "-form_content-label"}
          phx_debounce={@debounce}
        />
      </div>
      """
    end
  end

  setup do
    n = System.unique_integer([:positive])
    site = site!("editor-#{n}")
    other = site!("editor-other-#{n}")
    :ok = Translations.put_site(site.id)

    user = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

    {:ok,
     n: n,
     site: site,
     user: user,
     own: callout!(site, "callout-#{n}"),
     shared: callout!(nil, "shared-#{n}"),
     theirs: callout!(other, "theirs-#{n}")}
  end

  defp site!(name) do
    site = create_site!(name: name, host: "#{name}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  # A component the site may draw, known to `SiteState` as the compile worker would make it.
  defp callout!(site, name, overrides \\ []) do
    component =
      [
        name: name,
        site_id: site && site.id,
        active: true,
        precompile: false,
        description: "A boxed note",
        template:
          ~S|<aside class="probe-callout" data-title={@title} data-tone={@tone}>{render_slot(@inner_block)}</aside>|,
        attrs: [
          %{"name" => "title", "type" => "string", "opts" => %{"default" => nil}},
          %{
            "name" => "tone",
            "type" => "string",
            "opts" => %{"default" => "info", "values" => ["info", "warn"]}
          },
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ],
        slots: [%{"name" => "inner_block", "opts" => %{}}]
      ]
      |> Keyword.merge(overrides)
      |> create_component!()

    :ok = SiteState.put_component(component.site_id, component.name)
    on_exit(fn -> SiteState.delete_component(component.site_id, component.name) end)
    component
  end

  defp open(ctx, session \\ %{}) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: Map.merge(%{"user" => ctx.user, "value" => "<p>Stored</p>"}, session)
      )

    view
  end

  defp open_palette(view) do
    view |> element(@components <> "-toggle") |> render_click()
    render_async(view, @await)
    view
  end

  # What the hook's `pushEventTo(data-components, …)` sends.
  defp ask(view, event, payload),
    do: view |> with_target(@components) |> render_hook(event, payload)

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

  describe "the editor the adapter draws" do
    test "is Chelekom's editor contract, with the field's name on the hidden textarea", ctx do
      view = open(ctx)

      assert has_element?(view, "##{@editor}[data-part=root]")
      assert has_element?(view, "##{@editor} [data-part=toolbar][role=toolbar]")

      assert has_element?(
               view,
               "##{@editor}-surface[data-part=surface][phx-hook=ContentEditor][phx-update=ignore]" <>
                 "[data-root-id=#{@editor}][data-value-id=#{@editor}-value][data-format=html]" <>
                 "[data-value='<p>Stored</p>'][data-components='#{@components}']" <>
                 "[data-label-id=post_form-form_content-label][data-placeholder='Write the post']"
             )

      # The engine's editable element is the textbox, named from `data-label-id`; the surface
      # around it is not a second one.
      refute has_element?(view, "##{@editor}-surface[role]")

      assert view |> element("textarea##{@editor}-value[data-part=value][hidden]") |> render() =~
               ~s(name="form[content]")

      refute has_element?(view, "textarea##{@editor}-value[phx-change]")
      assert has_element?(view, "##{@editor}-surface [data-role=content-editor-loading]")

      for command <-
            ~w(paragraph h2 h3 h4 bold italic link bullet_list ordered_list blockquote code_block horizontal_rule undo redo) do
        assert has_element?(view, "##{@editor} button[data-editor-command=#{command}]")
      end

      assert has_element?(view, @components)
    end

    test "an empty field with no placeholder of its own says what to do", ctx do
      view = open(ctx, %{"value" => nil, "placeholder" => nil})

      assert has_element?(
               view,
               "##{@editor}-surface[data-placeholder='Write here — or place a component from Components.']"
             )
    end

    test "the document scrolls inside the editor, so the toolbar stays in view", ctx do
      view = open(ctx)

      assert view |> element("##{@editor}-surface") |> render() =~ "overflow-y-auto"
      assert view |> element("##{@editor}-surface") |> render() =~ "max-h-["
    end

    test "two forms on one page draw two editors", ctx do
      view = open(ctx, %{"forms" => ["post_form", "note_form"]})

      assert has_element?(view, "#post_form-form_content-editor-surface")
      assert has_element?(view, "#note_form-form_content-editor-surface")
      assert has_element?(view, "#note_form-form_content-editor-components")
    end

    test "every other textarea is still a textarea, and a code field still a code editor", ctx do
      view = open(ctx, %{"extra" => %{}})

      assert has_element?(view, "textarea#post_form-form_content[name='form[content]']")
      refute has_element?(view, "[data-part=root]")

      view = open(ctx, %{"extra" => %{code: "js"}})

      assert has_element?(view, "[phx-hook=PbCodeEditor] textarea[name='form[content]']")
      refute has_element?(view, "[phx-hook=ContentEditor]")
    end

    test "every other textarea is the Tailwind adapter's, with the field's own debounce", ctx do
      for debounce <- [300, 500, "blur", nil] do
        session = %{"extra" => %{}, "debounce" => debounce}
        admin = plain_textarea(ctx, session)

        assert admin ==
                 plain_textarea(ctx, Map.put(session, "module", MishkaGervaz.UIAdapters.Tailwind)),
               "debounce #{inspect(debounce)}"

        assert admin |> LazyHTML.from_fragment() |> LazyHTML.attribute("class") ==
                 [MishkaGervaz.UIAdapters.Tailwind.multiline_class("")]
      end
    end

    test "a code field is drawn at its rows' height, debounced by the field or 300ms", ctx do
      for {debounce, sent} <- [{300, "300"}, {500, "500"}, {nil, "300"}, {"blur", "300"}] do
        view = open(ctx, %{"extra" => %{code: "js"}, "debounce" => debounce})

        assert has_element?(
                 view,
                 "#gvz-code-post_form-form_content[phx-hook=PbCodeEditor][phx-update=ignore]" <>
                   "[data-language=js][class*='h-[14rem]']"
               )

        assert has_element?(
                 view,
                 "#gvz-code-post_form-form_content textarea#post_form-form_content" <>
                   "[name='form[content]'][rows='8'][phx-debounce='#{sent}']"
               ),
               "debounce #{inspect(debounce)}"
      end
    end
  end

  defp plain_textarea(ctx, session),
    do: ctx |> open(session) |> element("textarea#post_form-form_content") |> render()

  describe "the palette" do
    test "offers the site's own components and the shared ones, never another site's", ctx do
      view = ctx |> open() |> open_palette()

      assert has_element?(
               view,
               "#{@components}-pick-#{ctx.own.name}[data-component-card][draggable]"
             )

      assert has_element?(view, "#{@components}-pick-#{ctx.shared.name}")
      refute has_element?(view, "#{@components}-pick-#{ctx.theirs.name}")
      assert has_element?(view, "#{@components}-pick-#{ctx.own.name}[data-configurable=true]")
    end

    test "searching narrows the list", ctx do
      view = ctx |> open() |> open_palette()

      view |> element("#{@components}-query") |> render_keyup(%{"value" => "shared"})

      assert has_element?(view, "#{@components}-pick-#{ctx.shared.name}")
      refute has_element?(view, "#{@components}-pick-#{ctx.own.name}")
    end

    test "is what a plugin answering runtime:content:editor_palette leaves of it", ctx do
      register_plugin(ContentEditorPalette, "runtime:content:editor_palette")
      Process.register(self(), :__content_editor_palette_probe__)

      hidden = callout!(ctx.site, "kept-unlisted-#{ctx.n}")
      view = ctx |> open() |> open_palette()

      site_id = ctx.site.id
      user_id = ctx.user.id
      assert_received {:editor_palette, ^site_id, count, %{id: ^user_id}} when count > 0

      assert has_element?(view, "#{@components}-pick-#{ctx.own.name}")
      refute has_element?(view, "#{@components}-pick-#{hidden.name}")

      assert {:ok, entries} = ContentComponents.palette(ctx.user, ctx.site.id)
      refute Enum.any?(entries, &(&1.name == hidden.name))
    end

    # The read under it pages by 250; a site past that lost the end of the alphabet — the issue's
    # "searching video finds nothing" on a site whose kit and own components came to 308.
    test "lists every component, past one page of them", ctx do
      for i <- 1..251 do
        create_component!(
          name: "many-#{ctx.n}-#{String.pad_leading(to_string(i), 3, "0")}",
          site_id: nil,
          active: true,
          precompile: false
        )
      end

      last = callout!(nil, "zz-last-#{ctx.n}")

      assert {:ok, entries} = ContentComponents.palette(ctx.user, ctx.site.id)
      assert Enum.any?(entries, &(&1.name == last.name))
      assert Enum.count(entries, &String.starts_with?(&1.name, "many-#{ctx.n}-")) == 251
    end

    test "leaves out a component that requires what no marker can hold", ctx do
      needy =
        callout!(ctx.site, "needs-list-#{ctx.n}",
          attrs: [%{"name" => "rows", "type" => "list", "opts" => %{"required" => true}}]
        )

      fine =
        callout!(ctx.site, "needs-id-#{ctx.n}",
          attrs: [%{"name" => "id", "type" => "string", "opts" => %{"required" => true}}]
        )

      assert {:ok, entries} = ContentComponents.palette(ctx.user, ctx.site.id)
      refute Enum.any?(entries, &(&1.name == needy.name))
      assert Enum.any?(entries, &(&1.name == fine.name))
    end

    test "with no plugin, is every component the site may embed", ctx do
      hidden = callout!(ctx.site, "kept-unlisted-#{ctx.n}")

      assert {:ok, entries} = ContentComponents.palette(ctx.user, ctx.site.id)
      assert Enum.any?(entries, &(&1.name == hidden.name))
    end
  end

  describe "opening stored content" do
    test "is split into its HTML and the components standing alone, each previewed after", ctx do
      marker =
        ~s([[component #{ctx.own.name} title="Hi" tone="warn"]]Read <b>this</b>[[/component]])

      html = "<p>Intro</p><p>#{marker}</p><p>Inline [[component #{ctx.own.name} /]] here</p>"

      view = open(ctx)
      ask(view, "segments", %{"html" => html})

      assert_reply(view, %{
        segments: [
          %{type: "html", html: "<p>Intro</p>"},
          %{type: "component", name: name, marker: ^marker},
          %{type: "html", html: "<p>Inline [[component " <> _inline}
        ]
      })

      assert name == ctx.own.name

      assert_push_event(
        view,
        "mishka:content_editor",
        %{id: @editor, previews: [%{marker: ^marker, preview: preview}]},
        @await
      )

      assert preview =~ ~s(data-title="Hi")
      assert preview =~ "Read <b>this</b>"
    end

    # The admin's stylesheet holds none of a kit's colours or variants, so a blockquote turned
    # `secondary` previewed as it was; the previews are drawn with this instead.
    test "tells the editor the stylesheet its previews are drawn with, once it is built", ctx do
      view = open(ctx)
      ask(view, "segments", %{"html" => "<p>[[component #{ctx.own.name} /]]</p>"})
      assert_reply(view, %{styles: nil})

      key = MishkaCmsCore.Runtime.ContentEditorStyles.key(ctx.site.id)
      assert_push_event(view, "mishka:content_editor", %{id: @editor, styles: href}, 30_000)
      assert href == "/assets/css/#{key}/#{AssetsState.hash(key, "css")}"

      ask(view, "segments", %{"html" => "<p>x</p>"})
      assert_reply(view, %{styles: ^href})
    end

    test "a preview never carries a script, an event attribute or a LiveView binding", ctx do
      danger =
        create_component!(
          name: "danger-#{ctx.n}",
          site_id: ctx.site.id,
          active: true,
          precompile: false,
          template:
            ~S|<div phx-click="boom" onclick="alert(1)"><script>alert(2)</script><b>safe</b></div>|
        )

      :ok = SiteState.put_component(danger.site_id, danger.name)
      on_exit(fn -> SiteState.delete_component(danger.site_id, danger.name) end)

      view = open(ctx)
      ask(view, "segments", %{"html" => "<p>[[component #{danger.name} /]]</p>"})

      assert_push_event(view, "mishka:content_editor", %{previews: [%{preview: preview}]}, @await)

      assert preview =~ "<b>safe</b>"
      refute preview =~ "phx-click"
      refute preview =~ "onclick"
      refute preview =~ "<script"
    end

    test "a component that raises as it is drawn previews as a notice, the others still drawn",
         ctx do
      broken =
        callout!(ctx.site, "broken-#{ctx.n}",
          template: ~S|<p>{String.to_integer("not a number")}</p>|
        )

      bad = "[[component #{broken.name} /]]"
      good = ~s([[component #{ctx.own.name} title="Fine" /]])

      view = open(ctx)
      ask(view, "segments", %{"html" => "<p>#{bad}</p><p>#{good}</p>"})

      assert_push_event(
        view,
        "mishka:content_editor",
        %{previews: [%{marker: ^good, preview: drawn}]},
        @await
      )

      assert_push_event(
        view,
        "mishka:content_editor",
        %{previews: [%{marker: ^bad, preview: notice}]},
        @await
      )

      assert drawn =~ ~s(data-title="Fine")
      assert notice =~ "could not be drawn with these settings"
      assert notice =~ broken.name
    end

    test "and the pieces, written back in order, are the content as it was stored", ctx do
      marker = ~s([[component #{ctx.own.name} title="Hi"]]x[[/component]])
      html = "<h2>T</h2><p>#{marker}</p>\n[[component #{ctx.shared.name} /]]<p>end</p>"

      view = open(ctx)
      ask(view, "segments", %{"html" => html})
      assert_reply(view, %{segments: segments})

      written =
        Enum.map_join(segments, fn
          %{type: "html", html: piece} -> piece
          %{type: "component", marker: block} -> "<p>" <> block <> "</p>"
        end)

      assert ContentComponents.parse(written) |> drawn() ==
               ContentComponents.parse(html) |> drawn()

      assert written ==
               "<h2>T</h2><p>#{marker}</p>\n<p>[[component #{ctx.shared.name} /]]</p><p>end</p>"
    end
  end

  # What a page draws from content: its HTML around the markers, and each marker's component.
  defp drawn(chunks) do
    Enum.map(chunks, fn
      {:html, html} -> {:html, html |> String.replace(~r{\s+}, "")}
      {:component, marker} -> {:component, Map.delete(marker, :index)}
    end)
    |> Enum.reject(&(&1 == {:html, ""}))
  end

  describe "building a component" do
    test "a palette component is written by the server, with only what it declares", ctx do
      view = ctx |> open() |> open_palette()

      ask(view, "build", %{
        "name" => ctx.own.name,
        "attrs" => %{"title" => "Heads up", "tone" => "warn", "phx-click" => "boom", "id" => "x"},
        "inner" => "Read <b>this</b>"
      })

      marker =
        ~s([[component #{ctx.own.name} title="Heads up" tone="warn"]]Read <b>this</b>[[/component]])

      assert_reply(view, %{name: name, marker: ^marker})
      assert name == ctx.own.name

      assert_push_event(view, "mishka:content_editor", %{previews: [%{marker: ^marker}]}, @await)
    end

    test "a component placed closes the palette, off the text", ctx do
      view = ctx |> open() |> open_palette()
      assert has_element?(view, "#{@components}-panel")

      ask(view, "build", %{"name" => ctx.shared.name, "attrs" => %{}, "inner" => ""})
      assert_reply(view, %{marker: _marker})

      refute has_element?(view, "#{@components}-panel")
    end

    test "and so does opening a placed component's settings", ctx do
      view = ctx |> open() |> open_palette()
      ask(view, "edit", %{"marker" => "[[component #{ctx.own.name} /]]"})

      refute has_element?(view, "#{@components}-panel")
      assert in_drawer?(view, "#{@components}-drawer")
    end

    test "a component that requires a slot is written with an empty entry for it", ctx do
      player = player!(ctx.site, "player-#{ctx.n}")
      view = ctx |> open() |> open_palette()

      ask(view, "build", %{"name" => player.name, "attrs" => %{}, "inner" => ""})

      expected = "[[component #{player.name}]][[slot source /]][[/component]]"
      assert_reply(view, %{marker: ^expected})
    end

    test "a refusal keeps the palette open, and says why", ctx do
      view = ctx |> open() |> open_palette()

      ask(view, "build", %{"name" => ctx.theirs.name, "attrs" => %{}, "inner" => ""})
      assert_reply(view, %{error: _message})

      assert has_element?(view, "#{@components}-panel")
      assert has_element?(view, "#{@components}-notice")
    end

    test "nothing filled in is the self-closing marker", ctx do
      view = ctx |> open() |> open_palette()
      ask(view, "build", %{"name" => ctx.shared.name, "attrs" => %{}, "inner" => ""})

      expected = "[[component #{ctx.shared.name} /]]"
      assert_reply(view, %{marker: ^expected})
    end

    test "another site's component, or one no site has, is refused", ctx do
      view = ctx |> open() |> open_palette()

      for name <- [ctx.theirs.name, "nobody-has-#{ctx.n}", "bad name!"] do
        ask(view, "build", %{"name" => name, "attrs" => %{}, "inner" => ""})
        assert_reply(view, %{error: message})
        assert message =~ "is not a component this site can place"
      end
    end

    test "before the palette is read, nothing is built", ctx do
      view = open(ctx)
      ask(view, "build", %{"name" => ctx.own.name, "attrs" => %{}, "inner" => ""})

      assert_reply(view, %{error: _message})
    end

    test "no name a request carries becomes an atom", ctx do
      view = ctx |> open() |> open_palette()
      names = for _ <- 1..200, do: "ghost-#{System.unique_integer([:positive])}"

      before = :erlang.system_info(:atom_count)

      for name <- names do
        ask(view, "build", %{"name" => name, "attrs" => %{name => "v"}, "inner" => ""})
        ask(view, "edit", %{"marker" => "[[component #{name} #{name}=\"v\" /]]"})
        ask(view, "segments", %{"html" => "<p>[[component #{name} #{name}=\"v\" /]]</p>"})
      end

      render_async(view, @await)

      assert :erlang.system_info(:atom_count) - before < 100
    end
  end

  describe "the palette's headings" do
    test "are text first, a kit's own after the known ones, and Other last", ctx do
      callout!(ctx.site, "words-#{ctx.n}", type: "typography")
      callout!(ctx.site, "hero-#{ctx.n}", type: "marketing")

      view = ctx |> open() |> open_palette()

      assert category_ids(view) ==
               Enum.map(~w(all text marketing other), &"#{@picker}-category-#{&1}")

      assert section_titles(view) == ["Text", "Marketing", "Other"]
    end

    test "narrow the list to one heading", ctx do
      callout!(ctx.site, "words-#{ctx.n}", type: "typography")
      view = ctx |> open() |> open_palette()

      view |> element("#{@components}-category-text") |> render_click()

      assert has_element?(view, "#{@components}-pick-words-#{ctx.n}")
      refute has_element?(view, "#{@components}-pick-#{ctx.own.name}")
    end

    test "are searched by their name", ctx do
      callout!(ctx.site, "words-#{ctx.n}", type: "typography")
      view = ctx |> open() |> open_palette()

      view |> element("#{@components}-query") |> render_keyup(%{"value" => "text"})

      assert has_element?(view, "#{@components}-pick-words-#{ctx.n}")
      refute has_element?(view, "#{@components}-pick-#{ctx.own.name}")
    end

    test "the search box is cleared by its own button", ctx do
      view = ctx |> open() |> open_palette()
      view |> element("#{@components}-query") |> render_keyup(%{"value" => "zzz-nothing"})
      refute has_element?(view, "#{@components}-pick-#{ctx.own.name}")

      view |> element("#{@components}-query-clear") |> render_click()

      assert has_element?(view, "#{@components}-pick-#{ctx.own.name}")
      refute has_element?(view, "#{@components}-query-clear")
    end
  end

  defp category_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@components}-categories button")
    |> LazyHTML.attribute("id")
  end

  defp section_titles(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@components}-list section > div > span:first-child")
    |> Enum.map(&LazyHTML.text/1)
  end

  describe "ready blocks" do
    setup ctx do
      register_plugin(ContentEditorBlocks, "runtime:content:editor_blocks")

      block = %{
        id: "note-#{ctx.n}",
        title: "Boxed note",
        component: ctx.own.name,
        category: "layout",
        tree: %{
          name: ctx.own.name,
          attrs: %{"title" => "Outer"},
          parts: [{:component, %{name: ctx.shared.name, attrs: %{}, parts: []}}]
        }
      }

      unplaceable = %{block | id: "theirs-#{ctx.n}", tree: %{block.tree | name: ctx.theirs.name}}

      :persistent_term.put(:__content_editor_blocks__, [block, unplaceable])
      on_exit(fn -> :persistent_term.erase(:__content_editor_blocks__) end)

      {:ok, block: block}
    end

    test "open first, offering the blocks whose components the site may place", ctx do
      view = ctx |> open() |> open_palette()

      assert has_element?(view, "#{@components}-tab-blocks[aria-selected=true]")
      assert has_element?(view, "#{@components}-block-note-#{ctx.n}[data-block-card][draggable]")
      refute has_element?(view, "#{@components}-block-theirs-#{ctx.n}")
    end

    test "a block is written by the server, components inside it", ctx do
      view = ctx |> open() |> open_palette()

      ask(view, "block", %{"id" => "note-#{ctx.n}"})

      marker =
        ~s([[component #{ctx.own.name} title="Outer"]][[component #{ctx.shared.name} /]][[/component]])

      assert_reply(view, %{marker: ^marker})
      refute has_element?(view, "#{@components}-panel")
      assert_push_event(view, "mishka:content_editor", %{previews: [%{marker: ^marker}]}, @await)
    end

    test "are the examples the site's components carry", ctx do
      callout!(ctx.site, "framed-#{ctx.n}",
        examples: [
          ~s(<.component component_name="framed-#{ctx.n}" id="framed-welcome" title="Hello">\n  Welcome <.component component_name="#{ctx.shared.name}" />\n</.component>),
          ~s(<.component component_name="framed-#{ctx.n}">{@title}</.component>)
        ]
      )

      view = ctx |> open() |> open_palette()

      assert has_element?(view, "#{@components}-block-framed-#{ctx.n}-example-1", "Welcome")
      refute has_element?(view, "#{@components}-block-framed-#{ctx.n}-example-2")

      ask(view, "block", %{"id" => "framed-#{ctx.n}-example-1"})

      marker =
        ~s([[component framed-#{ctx.n} title="Hello"]]Welcome [[component #{ctx.shared.name} /]][[/component]])

      assert_reply(view, %{marker: ^marker})
    end

    test "a block nobody offers is refused", ctx do
      view = ctx |> open() |> open_palette()

      ask(view, "block", %{"id" => "theirs-#{ctx.n}"})
      assert_reply(view, %{error: _message})
    end

    test "the Components tab lists the components, and its search searches them", ctx do
      view = ctx |> open() |> open_palette()

      view |> element("#{@components}-tab-components") |> render_click()

      assert has_element?(view, "#{@components}-tab-components[aria-selected=true]")
      assert has_element?(view, "#{@components}-pick-#{ctx.own.name}")
      refute has_element?(view, "#{@components}-block-note-#{ctx.n}")
    end
  end

  describe "dropping a component on a placed one" do
    test "puts it inside, at the end", ctx do
      view = ctx |> open() |> open_palette()

      ask(view, "nest", %{
        "marker" => ~s([[component #{ctx.own.name}]]Text[[/component]]),
        "name" => ctx.shared.name
      })

      marker =
        ~s([[component #{ctx.own.name}]]Text[[component #{ctx.shared.name} /]][[/component]])

      assert_reply(view, %{name: _name, marker: ^marker})
    end

    test "is refused where the component holds nothing, or either is not listed", ctx do
      flat = callout!(ctx.site, "flat-#{ctx.n}", slots: [])
      view = ctx |> open() |> open_palette()

      for {marker, name} <- [
            {"[[component #{flat.name} /]]", ctx.shared.name},
            {"[[component #{ctx.own.name} /]]", ctx.theirs.name},
            {"[[component #{ctx.theirs.name} /]]", ctx.own.name},
            {"<p>not a marker</p>", ctx.own.name}
          ] do
        ask(view, "nest", %{"marker" => marker, "name" => name})
        assert_reply(view, %{error: _message})
      end
    end
  end

  # THE DRAWER IS IN A PORTAL, which `Phoenix.LiveViewTest` keeps inside the `<template>` the browser
  # moves to the body — it does not look in there. So the drawer is read out of the template, and its
  # events are sent to the picker it belongs to, as the browser does.
  defp drawer(view) do
    html = render(view)

    case Regex.run(~r{<template id="#{@picker}-drawer-portal"[^>]*>(.*?)</template>}s, html) do
      [_template, inside] -> LazyHTML.from_fragment(inside)
      nil -> LazyHTML.from_fragment("")
    end
  end

  defp in_drawer?(view, selector), do: view |> drawer() |> LazyHTML.query(selector) |> Enum.any?()

  defp drawer_html(view, selector),
    do: view |> drawer() |> LazyHTML.query(selector) |> LazyHTML.to_html()

  defp push(view, event, params \\ %{}),
    do: view |> with_target(@components) |> render_click(event, params)

  defp edit(view, marker) do
    ask(view, "edit", %{"marker" => marker})
    assert_reply(view, %{ok: true})
    view
  end

  defp settings_change(view, params), do: push(view, "settings_change", params)

  defp applied(view) do
    assert_push_event(view, "mishka:content_editor", %{applied: %{marker: marker}}, @await)
    marker
  end

  describe "a placed component's settings" do
    test "open in a drawer of their own, filled in from its marker", ctx do
      view =
        ctx
        |> open()
        |> open_palette()
        |> edit(~s([[component #{ctx.own.name} title="Hi" tone="warn"]]Body[[/component]]))

      assert in_drawer?(view, "#{@components}-drawer[data-editor=#{@editor}]")

      assert in_drawer?(
               view,
               "form#{@components}-settings[phx-change=settings_change][phx-submit=settings_done]"
             )

      assert in_drawer?(view, "#{@components}-f-r-title[name='a[r][title]'][value=Hi]")
      assert in_drawer?(view, "#{@components}-f-r-tone option[value=warn][selected]")
      assert drawer_html(view, "#{@components}-text-r-0") =~ "Body"
      refute in_drawer?(view, "#{@components}-f-r-rest")
      refute has_element?(view, "#{@components}-settings")
    end

    test "open once the palette is read, when it had not been", ctx do
      view = open(ctx)

      ask(view, "edit", %{"marker" => ~s([[component #{ctx.own.name} title="Late" /]])})
      assert_reply(view, %{ok: true})
      render_async(view, @await)

      assert in_drawer?(view, "#{@components}-f-r-title[value=Late]")
    end

    test "write each change back into the component, as it is typed", ctx do
      view =
        ctx
        |> open()
        |> open_palette()
        |> edit(~s([[component #{ctx.own.name} title="Hi"]]Body[[/component]]))

      settings_change(view, %{
        "a" => %{"r" => %{"title" => "Bye", "tone" => "warn"}},
        "t" => %{"r-0" => "New"}
      })

      assert applied(view) ==
               ~s([[component #{ctx.own.name} title="Bye" tone="warn"]]New[[/component]])

      assert_push_event(view, "mishka:content_editor", %{previews: [%{marker: _marker}]}, @await)
    end

    test "take only the attributes the component declares", ctx do
      view =
        ctx
        |> open()
        |> open_palette()
        |> edit("[[component #{ctx.own.name} /]]")

      settings_change(view, %{
        "a" => %{"r" => %{"title" => "T", "onclick" => "x", "phx-click" => "y"}}
      })

      assert applied(view) == ~s([[component #{ctx.own.name} title="T" /]])
    end

    test "an emptied field leaves the attribute to its default", ctx do
      view =
        ctx
        |> open()
        |> open_palette()
        |> edit(~s([[component #{ctx.own.name} title="Hi" /]]))

      settings_change(view, %{"a" => %{"r" => %{"title" => ""}}})

      assert applied(view) == "[[component #{ctx.own.name} /]]"
    end

    test "add text, a component and a slot entry inside, remove one and move one", ctx do
      player = player!(ctx.site, "player-#{ctx.n}")

      view =
        ctx
        |> open()
        |> open_palette()
        |> edit("[[component #{player.name}]][[slot source src=\"/a.mp4\" /]][[/component]]")

      assert in_drawer?(view, "#{@components}-add-slot-r-source")
      push(view, "part_add", %{"path" => "r", "kind" => "slot", "name" => "source"})
      assert applied(view) =~ ~s([[slot source src="/a.mp4" /]][[slot source /]])

      assert in_drawer?(view, "#{@components}-add-component-r")
      push(view, "child_open", %{"path" => "r"})
      assert in_drawer?(view, "#{@components}-child-r-#{ctx.shared.name}")
      push(view, "part_add", %{"path" => "r", "kind" => "component", "name" => ctx.shared.name})

      assert applied(view) ==
               ~s([[component #{player.name}]][[slot source src="/a.mp4" /]][[slot source /]][[component #{ctx.shared.name} /]][[/component]])

      refute in_drawer?(view, "#{@components}-children-r")

      push(view, "part_remove", %{"path" => "r-1"})

      assert applied(view) ==
               ~s([[component #{player.name}]][[slot source src="/a.mp4" /]][[component #{ctx.shared.name} /]][[/component]])

      push(view, "part_move", %{"path" => "r-1", "by" => "-1"})

      assert applied(view) ==
               ~s([[component #{player.name}]][[component #{ctx.shared.name} /]][[slot source src="/a.mp4" /]][[/component]])

      push(view, "part_add", %{"path" => "r", "kind" => "text"})
      settings_change(view, %{"t" => %{"r-2" => "After"}})

      assert applied(view) ==
               ~s([[component #{player.name}]][[component #{ctx.shared.name} /]][[slot source src="/a.mp4" /]]After[[/component]])
    end

    test "file the attributes under the page builder's headings, what is filled in open", ctx do
      view = ctx |> open() |> open_palette() |> edit("[[component #{ctx.own.name} /]]")

      assert in_drawer?(view, "#{@components}-f-r-title")
      refute in_drawer?(view, "details #{@components}-f-r-title")

      assert in_drawer?(
               view,
               "details#{@components}-group-r-properties[data-group=Properties][phx-mounted] #{@components}-f-r-tone"
             )
    end

    test "fold each part inside, saying what a folded one holds", ctx do
      player = player!(ctx.site, "player-#{ctx.n}")

      view =
        ctx
        |> open()
        |> open_palette()
        |> edit(
          ~s([[component #{player.name}]][[component #{ctx.own.name} title="Inner" /]][[slot source src="/a.mp4" /]][[/component]])
        )

      for {section, part} <- [{"node", "r-0"}, {"slot", "r-1"}] do
        id = "#{@components}-#{section}-#{part}"

        assert in_drawer?(view, "#{id}[phx-mounted] > [data-part=body]")
        assert in_drawer?(view, "#{id} > [data-part=head] button[data-part=fold][phx-click]")
        assert drawer_html(view, "#{id} > [data-part=head] [data-part=fold]") =~ "data-collapsed"
      end

      assert drawer_html(view, "#{@components}-node-r-0 > [data-part=head]") =~ "Inner"
      refute in_drawer?(view, "#{@components}-node-r > [data-part=head]")
    end

    test "show a text box added beside the slots at once", ctx do
      player = player!(ctx.site, "player-#{ctx.n}")

      view =
        ctx
        |> open()
        |> open_palette()
        |> edit(~s([[component #{player.name}]][[slot source src="/a.mp4" /]][[/component]]))

      refute in_drawer?(view, "#{@components}-text-r-1")
      push(view, "part_add", %{"path" => "r", "kind" => "text"})
      assert in_drawer?(view, "#{@components}-text-r-1")
    end

    test "give a component or a slot entry added inside a box for its text at once", ctx do
      tabs =
        callout!(ctx.site, "tabs-#{ctx.n}",
          attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}],
          template:
            ~S|<div class="probe-tabs"><div :for={t <- @tab}>{render_slot(t)}</div></div>|,
          slots: [%{"name" => "tab", "opts" => %{"required" => true}, "attrs" => []}]
        )

      view =
        ctx
        |> open()
        |> open_palette()
        |> edit(~s([[component #{ctx.own.name}]]Body[[/component]]))

      push(view, "part_add", %{"path" => "r", "kind" => "component", "name" => tabs.name})
      assert in_drawer?(view, "#{@components}-text-r-1-0-0")

      push(view, "part_add", %{"path" => "r-1", "kind" => "slot", "name" => "tab"})
      assert in_drawer?(view, "#{@components}-text-r-1-1-0")
    end

    test "write each text box, and each line in one, as a line of its own", ctx do
      view =
        ctx
        |> open()
        |> open_palette()
        |> edit(~s([[component #{ctx.own.name}]]One[[/component]]))

      push(view, "part_add", %{"path" => "r", "kind" => "text"})
      settings_change(view, %{"t" => %{"r-1" => "Two\r\nThree"}})

      marker = ~s([[component #{ctx.own.name}]]One<br>Two<br>Three[[/component]])
      assert applied(view) == marker

      push(view, "settings_done")
      edit(view, marker)

      assert drawer_html(view, "#{@components}-text-r-0") =~ "One\nTwo\nThree"
    end

    test "a path that leads nowhere, or a component not listed, changes nothing", ctx do
      view = ctx |> open() |> open_palette() |> edit("[[component #{ctx.own.name} /]]")

      push(view, "part_remove", %{"path" => "r-9"})
      push(view, "part_remove", %{"path" => "r--1"})
      push(view, "part_remove", %{"path" => "r"})
      push(view, "part_move", %{"path" => "r-0", "by" => "1"})
      push(view, "part_add", %{"path" => "r", "kind" => "component", "name" => ctx.theirs.name})
      push(view, "part_add", %{"path" => "r", "kind" => "slot", "name" => "nope"})
      push(view, "part_add", %{"path" => "nowhere", "kind" => "text"})

      refute_push_event(view, "mishka:content_editor", %{applied: _})
    end

    test "a slot entry's attributes are its own", ctx do
      player = player!(ctx.site, "player-#{ctx.n}")

      view =
        ctx
        |> open()
        |> open_palette()
        |> edit("[[component #{player.name}]][[slot source /]][[/component]]")

      assert in_drawer?(view, "[data-content-slot=r-0][data-name=source]")

      settings_change(view, %{
        "a" => %{"r-0" => %{"src" => "/b.mp4", "type" => "video/mp4", "x" => "y"}}
      })

      assert applied(view) ==
               ~s([[component #{player.name}]][[slot source src="/b.mp4" type="video/mp4" /]][[/component]])
    end

    test "Done closes them and tells the editor", ctx do
      view = ctx |> open() |> open_palette() |> edit("[[component #{ctx.own.name} /]]")

      assert in_drawer?(view, "#{@components}-drawer-close[phx-click=settings_done]")
      push(view, "settings_done")

      refute in_drawer?(view, "#{@components}-drawer")
      assert_push_event(view, "mishka:content_editor", %{id: @editor, done: true})
    end

    test "say so for a component this site may not place", ctx do
      view = ctx |> open() |> open_palette()
      ask(view, "edit", %{"marker" => "[[component #{ctx.theirs.name} /]]"})

      assert_reply(view, %{error: _message})
      assert has_element?(view, "#{@components}-notice")
      refute in_drawer?(view, "#{@components}-drawer")
    end
  end

  describe "a picture from the media library" do
    setup ctx do
      picture =
        callout!(ctx.site, "picture-#{ctx.n}",
          attrs: [%{"name" => "src", "type" => "string", "opts" => %{}}],
          template: ~S|<img class="probe-picture" src={@src} />|,
          slots: []
        )

      {:ok, picture: picture}
    end

    test "is chosen in the library, opened for the field", ctx do
      view =
        ctx
        |> open()
        |> open_palette()
        |> edit("[[component #{ctx.picture.name} /]]")

      assert in_drawer?(
               view,
               "#{@components}-f-r-src-choose[phx-click=media_open][phx-value-path=r][phx-value-attr=src]"
             )

      push(view, "media_open", %{"path" => "r", "attr" => "src"})

      assert in_drawer?(view, "#{@components}-media[data-role=content-media-chooser]")
      refute in_drawer?(view, "#{@components}-settings")

      Phoenix.LiveView.send_update(view.pid, ContentComponentPicker,
        id: @picker,
        media: %{url: "/uploads/a.png"}
      )

      assert applied(view) == ~s([[component #{ctx.picture.name} src="/uploads/a.png" /]])
      assert in_drawer?(view, "#{@components}-settings")
    end

    test "Back returns to the settings, changing nothing", ctx do
      view =
        ctx
        |> open()
        |> open_palette()
        |> edit("[[component #{ctx.picture.name} /]]")

      push(view, "media_open", %{"path" => "r", "attr" => "src"})
      Phoenix.LiveView.send_update(view.pid, ContentComponentPicker, id: @picker, media: :closed)

      assert in_drawer?(view, "#{@components}-settings")
      refute_push_event(view, "mishka:content_editor", %{applied: _})
    end

    test "a pick that arrives after the library closed changes nothing", ctx do
      view = ctx |> open() |> open_palette() |> edit("[[component #{ctx.picture.name} /]]")

      Phoenix.LiveView.send_update(view.pid, ContentComponentPicker,
        id: @picker,
        media: %{url: "/late.png"}
      )

      assert in_drawer?(view, "#{@components}-settings")
      refute_push_event(view, "mishka:content_editor", %{applied: _})
    end

    test "a file chosen for a source sets its kind", ctx do
      player = player!(ctx.site, "player-#{ctx.n}")

      view =
        ctx
        |> open()
        |> open_palette()
        |> edit("[[component #{player.name}]][[slot source /]][[/component]]")

      for {file, kind} <- [{"/u/clip.webm", "video/webm"}, {"/u/clip.mp4", "video/mp4"}] do
        push(view, "media_open", %{"path" => "r-0", "attr" => "src"})

        Phoenix.LiveView.send_update(view.pid, ContentComponentPicker,
          id: @picker,
          media: %{url: file}
        )

        assert applied(view) ==
                 ~s([[component #{player.name}]][[slot source src="#{file}" type="#{kind}" /]][[/component]])
      end
    end

    test "a video's file is chosen among the videos", ctx do
      player = player!(ctx.site, "player-#{ctx.n}")

      view =
        ctx
        |> open()
        |> open_palette()
        |> edit("[[component #{player.name}]][[slot source /]][[/component]]")

      push(view, "media_open", %{"path" => "r-0", "attr" => "src"})

      assert drawer_html(view, "#{@components}-media") =~ "Choose a video"
    end
  end

  defp player!(site, name),
    do:
      callout!(site, name,
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}],
        template:
          ~S|<div class="probe-player"><span :for={s <- @source} data-src={s.src}></span>{render_slot(@inner_block)}</div>|,
        slots: [
          %{"name" => "inner_block", "opts" => %{}},
          %{
            "name" => "source",
            "opts" => %{"required" => true},
            "attrs" => [
              %{"name" => "src", "type" => "string", "opts" => %{"required" => true}},
              %{"name" => "type", "type" => "string", "opts" => %{}}
            ]
          }
        ]
      )
end
