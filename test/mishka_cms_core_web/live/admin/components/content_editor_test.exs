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
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.ContentEditorPalette

  @moduletag :integration

  @endpoint MishkaCmsCore.TestEndpoint
  @await 5_000

  @editor "post_form-form_content-editor"
  @components "#post_form-form_content-editor-components"

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
  defp callout!(site, name) do
    component =
      create_component!(
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
      )

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

    test "and so does Apply in a placed component's settings", ctx do
      view = ctx |> open() |> open_palette()
      ask(view, "edit", %{"marker" => "[[component #{ctx.own.name} /]]"})
      assert has_element?(view, "#{@components}-settings")

      ask(view, "build", %{"name" => ctx.own.name, "attrs" => %{"title" => "T"}, "inner" => ""})
      assert_reply(view, %{marker: _marker})

      refute has_element?(view, "#{@components}-panel")
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

  describe "a placed component's settings" do
    test "open filled in from its marker", ctx do
      view = ctx |> open() |> open_palette()

      ask(view, "edit", %{
        "marker" => ~s([[component #{ctx.own.name} title="Hi" tone="warn"]]Body[[/component]])
      })

      assert_reply(view, %{ok: true})

      assert has_element?(
               view,
               "#{@components}-settings[data-content-editor-settings=#{ctx.own.name}]"
             )

      assert has_element?(
               view,
               "#{@components}-attr-title[data-content-editor-attr=title][value=Hi]"
             )

      assert has_element?(view, "#{@components}-attr-tone option[value=warn][selected]")
      assert view |> element("#{@components}-inner") |> render() =~ "Body"
      assert has_element?(view, "#{@components}-apply[data-content-editor-apply=#{ctx.own.name}]")
      refute has_element?(view, "#{@components}-attr-rest")
    end

    test "open once the palette is read, when it had not been", ctx do
      view = open(ctx)

      ask(view, "edit", %{"marker" => ~s([[component #{ctx.own.name} title="Late" /]])})
      assert_reply(view, %{ok: true})
      render_async(view, @await)

      assert has_element?(view, "#{@components}-attr-title[value=Late]")
    end

    test "belong to no form, so typing in them never reaches the record's", ctx do
      view = ctx |> open() |> open_palette()
      ask(view, "edit", %{"marker" => "[[component #{ctx.own.name} /]]"})

      assert has_element?(
               view,
               "#{@components}-attr-title[form='#{@components |> String.trim_leading("#")}-detached']"
             )

      refute has_element?(view, "form##{@components |> String.trim_leading("#")}-detached")
    end

    test "say so for a component this site may not place", ctx do
      view = ctx |> open() |> open_palette()
      ask(view, "edit", %{"marker" => "[[component #{ctx.theirs.name} /]]"})

      assert_reply(view, %{error: _message})
      assert has_element?(view, "#{@components}-notice")
    end
  end
end
