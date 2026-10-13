defmodule MishkaCmsCore.Runtime.ContentComponentsRenderTest do
  @moduledoc """
  Markers in content drawn as the components they name — `rich_content/1` on a page, in a preview
  and inside a LiveView — and the list the editor's picker offers.

  The components are real rows compiled by the runtime on first use, on a site this process renders
  for, as a page on it would. Reading the marker itself is `MishkaCmsCore.Runtime.ContentComponentsTest`.

  `async: false` — `SiteState`, compiled modules and the event registry are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.{ContentComponents, LiveViewHelpers, StaticHelpers, Translations}
  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SiteState}
  alias MishkaCmsCore.Test.Plugins.{ContentComponentBeforeDraw, ContentComponentSlotArg}

  @moduletag :integration

  @endpoint MishkaCmsCore.TestEndpoint

  @note_attrs [
    %{"name" => "title", "type" => "string", "opts" => %{"default" => nil}},
    %{"name" => "count", "type" => "integer", "opts" => %{"default" => 0}},
    %{"name" => "open", "type" => "boolean", "opts" => %{"default" => false}},
    %{
      "name" => "size",
      "type" => "string",
      "opts" => %{"default" => "small", "values" => ["small", "large"]}
    },
    %{"name" => "rest", "type" => "global", "opts" => %{}}
  ]

  @note_template ~S|<aside class="probe-note" data-title={@title} data-count={@count} data-open={to_string(@open)} data-size={@size} {@rest}>{render_slot(@inner_block)}</aside>|

  setup do
    n = System.unique_integer([:positive])
    site = site!("content-#{n}")
    :ok = Translations.put_site(site.id)

    {:ok, site: site, n: n}
  end

  defp site!(name) do
    site = create_site!(name: name, host: "#{name}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  # WHAT THE COMPILE WORKER DOES FOR AN ACTIVE COMPONENT, which `testing: :manual` never runs: its
  # name goes into `SiteState`, the names a marker is checked against.
  defp known!(%{active: true} = component) do
    :ok = SiteState.put_component(component.site_id, component.name)
    on_exit(fn -> SiteState.delete_component(component.site_id, component.name) end)
    component
  end

  defp known!(component), do: component

  defp note!(site, name, opts \\ []) do
    [
      name: name,
      template: @note_template,
      attrs: @note_attrs,
      slots: [%{"name" => "inner_block", "opts" => %{}}],
      active: true,
      precompile: false,
      site_id: site && site.id
    ]
    |> Keyword.merge(opts)
    |> create_component!()
    |> known!()
  end

  defp live!(site, name) do
    known!(
      create_component!(
        name: name,
        site_id: site.id,
        stateful: true,
        active: true,
        template: ~s(<div id={@id} {@rest} data-role="probe-live">{@label}</div>),
        attrs: [
          %{"name" => "label", "type" => "string", "opts" => %{"default" => "cold"}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ],
        helpers: [
          %{
            "name" => "mount",
            "args" => "socket",
            "code" => "{:ok, Phoenix.Component.assign(socket, :n, 0)}"
          }
        ]
      )
    )
  end

  defp draw(html, site),
    do: %{html: html, site: site} |> LiveViewHelpers.rich_content() |> to_html()

  defp preview(html, site),
    do: %{html: html, site: site} |> StaticHelpers.rich_content() |> to_html()

  defp to_html(rendered), do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  # The module name the runtime would make for `name` on `site`, spelt out as a string so that
  # asking about it makes no atom — `Helpers.module_name/3`'s hash.
  defp module_string(name, site) do
    hash = :md5 |> :crypto.hash(name <> site) |> Base.encode16(case: :lower)
    "Elixir.MishkaCmsCore.Runtime.#{hash}.Component"
  end

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp attribute(html, selector, name),
    do: html |> query(selector) |> LazyHTML.attribute(name) |> List.first()

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

  describe "rich_content/1 — a marker drawn as its component" do
    test "draws the component with its cast attributes and its inner content", %{site: site, n: n} do
      note!(site, "note-#{n}")

      html =
        draw(
          ~s(<p>Before</p>[[component note-#{n} title="Heads up" count="3" open size="large" phx-click="boom" onclick="x"]]Body <b>bold</b>[[/component]]<p>After</p>),
          site.name
        )

      assert attribute(html, ".probe-note", "data-title") == "Heads up"
      assert attribute(html, ".probe-note", "data-count") == "3"
      assert attribute(html, ".probe-note", "data-open") == "true"
      assert attribute(html, ".probe-note", "data-size") == "large"
      assert html |> query(".probe-note b") |> LazyHTML.text() == "bold"
      assert html =~ "<p>Before</p>"
      assert html =~ "<p>After</p>"

      refute html =~ "[[component"
      refute html =~ "phx-click"
      refute html =~ "onclick"
    end

    test "the HTML attributes its global attribute takes reach the element, and nothing unsafe",
         %{site: site, n: n} do
      note!(site, "video-#{n}",
        template:
          ~S|<video class={["probe-video", @rest[:circle] && "rounded-full"]} {@rest}></video>|,
        attrs: [
          %{
            "name" => "rest",
            "type" => "global",
            "opts" => %{"include" => ["controls", "circle", "muted", "poster"]}
          }
        ],
        slots: []
      )

      html =
        draw(
          ~s([[component video-#{n} controls circle muted="false" aria-label="Intro" ) <>
            ~s|data-state="idle" poster="javascript:alert(1)" onplay="x" style="color:red" phx-click="boom" /]]|,
          site.name
        )

      assert html |> query(".probe-video[controls]") |> Enum.count() == 1
      assert attribute(html, ".probe-video", "class") == "probe-video rounded-full"
      assert attribute(html, ".probe-video", "aria-label") == "Intro"
      assert attribute(html, ".probe-video", "data-state") == "idle"
      assert attribute(html, ".probe-video", "muted") == nil
      assert attribute(html, ".probe-video", "poster") == nil
      refute html =~ "onplay"
      refute html =~ "style="
      refute html =~ "phx-click"
    end

    test "a value that does not cast leaves the component's default", %{site: site, n: n} do
      note!(site, "note-#{n}")

      html = draw(~s([[component note-#{n} count="many" size="huge" /]]), site.name)

      assert attribute(html, ".probe-note", "data-count") == "0"
      assert attribute(html, ".probe-note", "data-size") == "small"
    end

    test "a self-closing marker hands an empty inner block", %{site: site, n: n} do
      note!(site, "note-#{n}")

      html = draw(~s([[component note-#{n} /]]), site.name)

      assert html |> query(".probe-note") |> LazyHTML.text() == ""
    end

    test "a global component is drawn on any site", %{site: site, n: n} do
      note!(nil, "shared-note-#{n}")

      assert draw(~s([[component shared-note-#{n} title="g" /]]), site.name) =~ "probe-note"
      assert draw(~s([[component shared-note-#{n} title="g" /]]), nil) =~ "probe-note"
    end

    test "the site's own component wins over the global one of its name", %{site: site, n: n} do
      note!(nil, "both-#{n}", template: ~s(<i class="probe-global">global</i>))
      note!(site, "both-#{n}", template: ~s(<i class="probe-own">own</i>))

      html = draw("[[component both-#{n} /]]", site.name)

      assert html =~ "probe-own"
      refute html =~ "probe-global"
    end

    test "content with no marker is drawn as it is", %{site: site} do
      html = "<p>Plain <b>post</b></p>"

      assert draw(html, site.name) == html
    end

    # WHOEVER STORES CONTENT SANITIZES IT, ONCE, when it is written. Scrubbing it again here cost a
    # code-heavy post ~150 ms a view, so the HTML around a marker is drawn byte for byte — markup a
    # sanitizer would change included.
    test "the HTML around a marker is drawn byte for byte, never sanitized again", %{
      site: site,
      n: n
    } do
      note!(site, "note-#{n}", template: ~s(<i class="probe">x</i>))
      before = ~s(<p><font data-probe="kept">a</font></p>\n<pre class="hl"><span>b</span></pre>)
      after_marker = ~s(<marquee>c</marquee>)

      assert draw(before <> "[[component note-#{n} /]]" <> after_marker, site.name) ==
               before <> ~s(<i class="probe">x</i>) <> after_marker
    end

    test "a marker inside <code> stays text", %{site: site, n: n} do
      note!(site, "note-#{n}")

      html = draw(~s(<code>[[component note-#{n} /]]</code>), site.name)

      assert html == ~s(<code>[[component note-#{n} /]]</code>)
    end
  end

  describe "rich_content/1 — what is drawn as nothing" do
    test "a name nothing answers to", %{site: site, n: n} do
      assert draw(~s(<p>a</p>[[component nothing-#{n} /]]<p>b</p>), site.name) ==
               "<p>a</p><p>b</p>"
    end

    test "an inactive component", %{site: site, n: n} do
      note!(site, "off-#{n}", active: false)

      assert draw("[[component off-#{n} /]]", site.name) == ""
    end

    test "another site's component, named from this site's content", %{site: site, n: n} do
      other = site!("content-other-#{n}")
      note!(other, "theirs-#{n}")

      assert draw("[[component theirs-#{n} /]]", other.name) == ""
      assert draw("[[component theirs-#{n} /]]", site.name) == ""
    end

    test "a component that draws content itself", %{site: site, n: n} do
      known!(
        create_component!(
          name: "drawer-#{n}",
          site_id: site.id,
          active: true,
          template:
            ~s(<div class="probe-drawer"><.rich_content html={@body} site={@site} /></div>),
          attrs: [%{"name" => "body", "type" => "string", "opts" => %{"default" => ""}}]
        )
      )

      assert draw(~s([[component drawer-#{n} body="x" /]]), site.name) == ""
    end

    # A NAME AN AUTHOR TYPED IS A STRING UNTIL THE SITE IS KNOWN TO HAVE IT. A module name is an
    # atom, and atoms are never collected — so a name no active component has makes none, and leaves
    # no failure behind to remember it by.
    test "a name no component has, without making an atom or remembering it", %{
      site: site,
      n: n
    } do
      name = "typed-by-an-author-#{n}"
      [site_module, global_module] = Enum.map([site.name, "Global"], &module_string(name, &1))

      assert draw("[[component #{name} /]]", site.name) == ""
      assert preview("[[component #{name} /]]", site.name) =~ name

      for module <- [site_module, global_module] do
        assert_raise ArgumentError, fn -> String.to_existing_atom(module) end
      end

      refute Enum.any?(CompileFailureState.matching(:_), fn {key, _reason} ->
               inspect(key) =~ name
             end)
    end

    test "a row that exists but whose name the site does not know yet", %{site: site, n: n} do
      create_component!(
        name: "unlisted-#{n}",
        site_id: site.id,
        active: true,
        template: ~s(<i class="probe-unlisted">x</i>)
      )

      assert draw("[[component unlisted-#{n} /]]", site.name) == ""
    end

    test "a component missing an attribute it requires", %{site: site, n: n} do
      note!(site, "strict-#{n}",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{"required" => true}}],
        template: ~s(<p class="probe-strict">{@title}</p>)
      )

      assert draw("[[component strict-#{n} /]]", site.name) == ""
      assert draw(~s([[component strict-#{n} title="ok" /]]), site.name) =~ "probe-strict"
    end
  end

  # A TEMPLATE READS EVERY ATTRIBUTE IT DECLARES. Found drawing each of the kit's 269 components from
  # a bare marker: 26 read one that had no default and was not given — `@label`, `@name`, `@for` —
  # and raised, which on a page takes the page down.
  describe "rich_content/1 — attributes the marker leaves out" do
    test "one declared with no default is handed as nil", %{site: site, n: n} do
      note!(site, "loose-#{n}",
        attrs: [
          %{"name" => "label", "type" => "string", "opts" => %{}},
          %{"name" => "items", "type" => "list", "opts" => %{}},
          %{"name" => "size", "type" => "string", "opts" => %{"default" => "small"}}
        ],
        template:
          ~S'<p class="probe-loose" data-label={@label || "none"} data-items={inspect(@items)} data-size={@size}></p>'
      )

      html = draw("[[component loose-#{n} /]]", site.name)

      assert attribute(html, ".probe-loose", "data-label") == "none"
      assert attribute(html, ".probe-loose", "data-items") == "nil"
      assert attribute(html, ".probe-loose", "data-size") == "small"

      assert attribute(
               draw(~s([[component loose-#{n} label="Hi" /]]), site.name),
               ".probe-loose",
               "data-label"
             ) ==
               "Hi"
    end

    test "one whose default is its type's empty struct keeps it", %{site: site, n: n} do
      note!(site, "closable-#{n}",
        attrs: [
          %{
            "name" => "on_cancel",
            "type" => "struct",
            "struct_name" => "Phoenix.LiveView.JS",
            "opts" => %{"default_struct" => true}
          }
        ],
        template:
          ~S|<p class="probe-closable" data-cancel={JS.exec(@on_cancel, "phx-remove")}></p>|
      )

      assert draw("[[component closable-#{n} /]]", site.name) =~ "probe-closable"
    end

    test "a guest is handed as no visitor to one declaring current_user", %{site: site, n: n} do
      note!(site, "who-#{n}",
        attrs: [%{"name" => "current_user", "type" => "any", "opts" => %{}}],
        template: ~S|<p class="probe-who" data-guest={to_string(is_nil(@current_user))}></p>|
      )

      assert attribute(draw("[[component who-#{n} /]]", site.name), ".probe-who", "data-guest") ==
               "true"
    end
  end

  describe "rich_content/1 — markers inside markers, and slots" do
    defp row!(site, name),
      do:
        note!(site, name,
          attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}],
          template: ~S|<div class="probe-row">{render_slot(@inner_block)}</div>|
        )

    defp player!(site, name) do
      note!(site, name,
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}],
        slots: [
          %{
            "name" => "source",
            "opts" => %{"required" => true},
            "attrs" => [
              %{"name" => "src", "type" => "string", "opts" => %{"required" => true}},
              %{"name" => "type", "type" => "string", "opts" => %{}},
              %{"name" => "muted", "type" => "boolean", "opts" => %{}}
            ]
          },
          %{"name" => "caption", "opts" => %{}, "attrs" => []}
        ],
        template:
          ~S'<div class="probe-player"><span :for={s <- @source} class="probe-source" data-src={s.src} data-type={s[:type] || "none"} data-muted={to_string(s[:muted])}></span><div :for={c <- @caption} class="probe-caption">{render_slot(c)}</div></div>'
      )
    end

    test "a component inside another is drawn in its inner block", %{site: site, n: n} do
      row!(site, "row-#{n}")
      note!(site, "note-#{n}")

      html =
        draw(
          ~s(<p>[[component row-#{n}]]<p>[[component note-#{n} title="A" /]]</p>[[component note-#{n} title="B"]]in [[component note-#{n} title="C" /]][[/component]][[/component]]</p>),
          site.name
        )

      assert html |> query(".probe-row > .probe-note") |> Enum.count() == 2

      assert html |> query(".probe-row .probe-note") |> LazyHTML.attribute("data-title") ==
               ["A", "B", "C"]

      refute html =~ "[[component"
      refute html =~ "<p>"
    end

    test "slot entries are passed as the slots the component declares", %{site: site, n: n} do
      player!(site, "player-#{n}")
      note!(site, "note-#{n}")

      html =
        draw(
          ~s([[component player-#{n}]][[slot source src="/a.mp4" type="video/mp4" muted /]][[slot source src="/b.webm" /]][[slot caption]]Hello <b>there</b> [[component note-#{n} title="in" /]][[/slot]][[slot unknown x="1" /]][[/component]]),
          site.name
        )

      assert html |> query(".probe-source") |> LazyHTML.attribute("data-src") == [
               "/a.mp4",
               "/b.webm"
             ]

      assert html |> query(".probe-source") |> LazyHTML.attribute("data-type") == [
               "video/mp4",
               "none"
             ]

      assert html |> query(".probe-source") |> LazyHTML.attribute("data-muted") == ["true", ""]
      assert html |> query(".probe-caption b") |> LazyHTML.text() == "there"
      assert attribute(html, ".probe-caption .probe-note", "data-title") == "in"
      refute html =~ "[[slot"
    end

    test "an entry holds only the attributes written on it, as a Phoenix slot entry does", %{
      site: site,
      n: n
    } do
      note!(site, "steps-#{n}",
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}],
        slots: [
          %{
            "name" => "item",
            "opts" => %{},
            "attrs" => [%{"name" => "position", "type" => "string", "opts" => %{}}]
          }
        ],
        template:
          ~S'<ol><li :for={i <- @item} class="probe-step" data-written={to_string(Map.has_key?(i, :position))} data-position={Map.get(i, :position, "start")}>{render_slot(i)}</li></ol>'
      )

      html =
        draw(
          ~s([[component steps-#{n}]][[slot item]]One[[/slot]][[slot item position="end"]]Two[[/slot]][[/component]]),
          site.name
        )

      assert html |> query(".probe-step") |> LazyHTML.attribute("data-written") == [
               "false",
               "true"
             ]

      assert html |> query(".probe-step") |> LazyHTML.attribute("data-position") == [
               "start",
               "end"
             ]
    end

    test "a slot nothing fills is passed empty", %{site: site, n: n} do
      player!(site, "player-#{n}")

      html =
        draw(~s([[component player-#{n}]][[slot source src="/a.mp4" /]][[/component]]), site.name)

      assert html |> query(".probe-source") |> Enum.count() == 1
      assert html |> query(".probe-caption") |> Enum.count() == 0
    end

    test "an entry written with nothing inside draws empty, and so does all around it", %{
      site: site,
      n: n
    } do
      row!(site, "row-#{n}")
      player!(site, "player-#{n}")

      html =
        draw(
          ~s([[component row-#{n}]][[component player-#{n}]][[slot source src="/a.mp4" /]][[slot caption /]][[/component]][[/component]]),
          site.name
        )

      assert html |> query(".probe-row .probe-player .probe-caption") |> Enum.count() == 1
      assert html |> query(".probe-caption") |> LazyHTML.text() == ""
    end

    test "a required slot, or a slot's required attribute, left out draws nothing", %{
      site: site,
      n: n
    } do
      player!(site, "player-#{n}")

      assert draw(~s([[component player-#{n} /]]), site.name) == ""
      assert preview(~s([[component player-#{n} /]]), site.name) =~ "source"

      without_src = ~s([[component player-#{n}]][[slot source type="video/mp4" /]][[/component]])

      assert draw(without_src, site.name) == ""
      assert preview(without_src, site.name) =~ "source.src"
    end

    test "a stateful component inside another gets an id under its parent's", %{
      site: site,
      n: n
    } do
      row!(site, "row-#{n}")
      live!(site, "live-#{n}")

      html =
        preview(
          ~s([[component live-#{n} /]][[component row-#{n}]][[component live-#{n} /]][[component live-#{n} /]][[/component]]),
          site.name
        )

      assert html |> query(~s([data-role="probe-live"])) |> LazyHTML.attribute("id") ==
               ["content-0", "content-1-0", "content-1-1"]
    end

    test "a marker in a slot entry gets an id of its own, never one in the inner block", %{
      site: site,
      n: n
    } do
      live!(site, "live-#{n}")

      note!(site, "box-#{n}",
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}],
        slots: [
          %{"name" => "inner_block", "opts" => %{}},
          %{"name" => "item", "opts" => %{}, "attrs" => []}
        ],
        template:
          ~S'<div>{render_slot(@inner_block)}<p :for={i <- @item}>{render_slot(i)}</p></div>'
      )

      html =
        preview(
          ~s([[component box-#{n}]][[component live-#{n} /]][[slot item]][[component live-#{n} /]][[/slot]][[slot item]][[component live-#{n} /]][[/slot]][[/component]]),
          site.name
        )

      assert html |> query(~s([data-role="probe-live"])) |> LazyHTML.attribute("id") ==
               ["content-0-0", "content-0-item-0-0", "content-0-item-1-0"]
    end

    test "content is drawn eight markers deep, and written as it is past that", %{
      site: site,
      n: n
    } do
      row!(site, "row-#{n}")
      note!(site, "note-#{n}")

      html =
        String.duplicate("[[component row-#{n}]]", 9) <>
          ~s([[component note-#{n} /]]) <> String.duplicate("[[/component]]", 9)

      drawn = draw(html, site.name)

      assert drawn |> query(".probe-row") |> Enum.count() == 9
      assert drawn |> query(".probe-note") |> Enum.count() == 0
      assert drawn =~ "[[component note-#{n} /]]"
    end
  end

  describe "rich_content/1 in a preview" do
    test "says why a marker draws nothing", %{site: site, n: n} do
      html = preview("[[component nothing-#{n} /]]", site.name)

      assert [_notice] =
               html |> query(~s([data-role="content-component-unavailable"])) |> Enum.to_list()

      assert html =~ "nothing-#{n}"
    end

    test "draws a stateful component cold", %{site: site, n: n} do
      live!(site, "live-#{n}")

      html = preview(~s([[component live-#{n} label="warm" /]]), site.name)

      assert attribute(html, ~s([data-role="probe-live"]), "id") == "content-0"
      assert html |> query(~s([data-role="probe-live"])) |> LazyHTML.text() == "warm"
    end
  end

  describe "runtime:render:before_content_component" do
    setup do
      register_plugin(ContentComponentBeforeDraw, "runtime:render:before_content_component")
    end

    test "a plugin changes what a marker draws", %{site: site, n: n} do
      note!(site, "note-#{n}")

      html =
        draw(
          ~s([[component note-#{n} title="first" /]][[component note-#{n} title="second" /]]),
          site.name
        )

      assert html |> query(".probe-note") |> LazyHTML.attribute("data-title") ==
               ["FIRST-0", "SECOND-1"]
    end

    test "and refuses one", %{site: site, n: n} do
      note!(site, "note-#{n}")

      html =
        draw(
          ~s([[component note-#{n} title="refuse" /]][[component note-#{n} title="kept" /]]),
          site.name
        )

      assert html |> query(".probe-note") |> LazyHTML.attribute("data-title") == ["KEPT-1"]
    end
  end

  describe "runtime:render:before_content_component — what a component hands its content" do
    setup do
      register_plugin(ContentComponentSlotArg, "runtime:render:before_content_component")
    end

    defp giver!(site, name, opts \\ []) do
      note!(
        site,
        name,
        Keyword.merge(
          [
            template:
              ~S|<section class="probe-giver">{render_slot(@inner_block, %{tag: @title})}</section>|
          ],
          opts
        )
      )
    end

    defp titles(html), do: html |> query(".probe-note") |> LazyHTML.attribute("data-title")

    test "reaches the markers inside, at any depth, nearest first, and none outside", %{
      site: site,
      n: n
    } do
      giver!(site, "giver-#{n}")
      row!(site, "row-#{n}")
      note!(site, "note-#{n}")

      html =
        draw(
          ~s([[component giver-#{n} title="outer"]][[component note-#{n} probe="seen" label="a" /]][[component row-#{n}]][[component note-#{n} probe="seen" label="b" /]][[component giver-#{n} title="inner"]][[component note-#{n} probe="seen" /]][[/component]][[/component]][[/component]][[component note-#{n} probe="seen" label="c" /]]),
          site.name
        )

      assert titles(html) == ["outer|outer|a", "outer|outer|b", "inner|inner,outer|", "none||c"]
    end

    test "a slot entry's value reaches the markers in that entry", %{site: site, n: n} do
      note!(site, "note-#{n}")

      note!(site, "slotted-#{n}",
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}],
        slots: [%{"name" => "item", "opts" => %{}, "attrs" => []}],
        template:
          ~S'<ul><li :for={i <- @item} class="probe-item">{render_slot(i, %{tag: "item"})}</li></ul>'
      )

      html =
        draw(
          ~s([[component slotted-#{n}]][[slot item]][[component note-#{n} probe="seen" /]][[/slot]][[/component]][[component note-#{n} probe="seen" /]]),
          site.name
        )

      assert titles(html) == ["item|item|", "none||"]
    end

    test "a component that hands nothing draws its content as before", %{site: site, n: n} do
      row!(site, "row-#{n}")
      note!(site, "note-#{n}")

      html =
        draw(
          ~s([[component row-#{n}]][[component note-#{n} probe="seen" /]][[component note-#{n} title="kept" /]][[/component]]),
          site.name
        )

      assert titles(html) == ["none||", "kept"]
      assert html |> query(".probe-row > .probe-note") |> Enum.count() == 2
    end

    test "reaches the markers inside a live component, from its own render", %{
      site: site,
      n: n
    } do
      note!(site, "note-#{n}")

      giver!(site, "live-giver-#{n}",
        stateful: true,
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}],
        template:
          ~S|<section id={@id} class="probe-giver">{render_slot(@inner_block, %{tag: "live-#{@n}"})}</section>|,
        helpers: [
          %{
            "name" => "mount",
            "args" => "socket",
            "code" => "{:ok, Phoenix.Component.assign(socket, :n, 7)}"
          }
        ]
      )

      view =
        mount_page(
          site,
          ~s([[component live-giver-#{n}]][[component note-#{n} probe="seen" /]][[/component]][[component note-#{n} probe="seen" /]])
        )

      assert has_element?(view, "#post-body-0 .probe-note[data-title='live-7|live-7|']")
      assert has_element?(view, "#host .probe-note[data-title='none||']")
    end

    test "a plugin leaves an attribute out altogether with unset", %{site: site, n: n} do
      note!(site, "probe-#{n}",
        attrs: [%{"name" => "label", "type" => "string", "opts" => %{}}],
        slots: [],
        template:
          ~S|<i class="probe-unset" data-has={to_string(Map.has_key?(assigns, :label))}></i>|
      )

      html =
        draw(
          ~s([[component probe-#{n} label="x" probe="unset" /]][[component probe-#{n} /]]),
          site.name
        )

      assert html |> query(".probe-unset") |> LazyHTML.attribute("data-has") == ["false", "true"]
    end
  end

  defmodule Host do
    use Phoenix.LiveView

    import MishkaCmsCore.Runtime.LiveViewHelpers, only: [rich_content: 1]

    def mount(_params, session, socket) do
      :ok = MishkaCmsCore.Runtime.Translations.put_site(session["site_id"])
      {:ok, assign(socket, html: session["html"], site: session["site"])}
    end

    def handle_info({:html, html}, socket), do: {:noreply, assign(socket, :html, html)}

    def render(assigns) do
      ~H"""
      <div id="host"><.rich_content id="post-body" html={@html} site={@site} /></div>
      """
    end
  end

  describe "rich_content/1 on a live page" do
    defp mount_page(site, html) do
      {:ok, view, _html} =
        live_isolated(Phoenix.ConnTest.build_conn(), Host,
          session: %{"html" => html, "site" => site.name, "site_id" => site.id}
        )

      view
    end

    test "draws a stateful component as a live component, its id from its place", %{
      site: site,
      n: n
    } do
      live!(site, "live-#{n}")
      note!(site, "note-#{n}")

      view =
        mount_page(
          site,
          ~s(<p>Intro</p>[[component note-#{n} title="n" /]][[component live-#{n} label="first" /]][[component live-#{n} label="second" /]])
        )

      assert has_element?(view, "#host .probe-note[data-title='n']")
      assert view |> element("#post-body-1") |> render() =~ "first"
      assert view |> element("#post-body-2") |> render() =~ "second"
      assert has_element?(view, "#host p", "Intro")
    end

    test "keeps each live component's id when the content around it changes", %{
      site: site,
      n: n
    } do
      live!(site, "live-#{n}")
      view = mount_page(site, ~s([[component live-#{n} label="kept" /]]))

      send(view.pid, {:html, ~s(<p>New intro</p>[[component live-#{n} label="kept" /]])})

      assert has_element?(view, "#post-body-0", "kept")
      assert has_element?(view, "#host p", "New intro")
    end
  end

  # THE STYLESHEET IS BUILT FROM WHAT A SITE REACHES, and the components content names are in no
  # template: whoever stores content says which, when the stylesheet is built.
  describe "TailwindCompiler.content_components/1" do
    test "is what the stored content of the site says it names", %{site: site} do
      register_plugin(
        MishkaCmsCore.Test.Plugins.ContentComponentsNamed,
        "runtime:compile:content_components"
      )

      assert TailwindCompiler.content_components(site.name) ==
               ["probe-from-content", "probe-from-content-#{site.name}"]
    end

    test "is nothing for a site that is not there, or that nothing answers for", %{site: site} do
      assert TailwindCompiler.content_components(site.name) == []
      assert TailwindCompiler.content_components("no-such-site") == []
    end
  end

  # AN ICON CONTENT NAMES IS IN NO TEMPLATE EITHER — a marker's `icon="hero-inbox"` reaches its
  # component as an expression — so the same event answers them, and the stylesheet carries them.
  describe "TailwindCompiler.content_icons/1" do
    setup do
      original = Application.get_env(:mishka_cms_core, :icon_libraries)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:mishka_cms_core, :icon_libraries)
          libraries -> Application.put_env(:mishka_cms_core, :icon_libraries, libraries)
        end
      end)

      Application.put_env(:mishka_cms_core, :icon_libraries, [
        MishkaCmsCore.Runtime.PageBuilder.Icons.Heroicons,
        MishkaCmsCore.Runtime.PageBuilder.IconLibraryTest.Fake
      ])

      :ok
    end

    test "is what the stored content of the site says it names, each once", %{site: site} do
      register_plugin(
        MishkaCmsCore.Test.Plugins.ContentComponentsNamed,
        "runtime:compile:content_components"
      )

      assert TailwindCompiler.content_icons(site.name) == ["hero-inbox-arrow-down", "fake-star"]
    end

    test "is nothing for a site that is not there, that nothing answers for, or while the event cannot run",
         %{site: site} do
      assert TailwindCompiler.content_icons(site.name) == []
      assert TailwindCompiler.content_icons("no-such-site") == []

      MishkaCmsCore.Test.EventCannotRun.stub!("runtime:compile:content_components")

      assert TailwindCompiler.content_icons(site.name) == []
      assert TailwindCompiler.content_components(site.name) == []
    end

    test "each has a rule in the site's stylesheet, whichever registered set ships it", %{
      site: site
    } do
      on_exit(fn -> MishkaCmsCore.Runtime.States.AssetsState.delete("__shared_base__", "css") end)

      assert {:ok, unnamed} = TailwindCompiler.compile(site.name)
      refute site_part(unnamed, site) =~ ".hero-inbox-arrow-down{"
      refute site_part(unnamed, site) =~ ".fake-star{"

      register_plugin(
        MishkaCmsCore.Test.Plugins.ContentComponentsNamed,
        "runtime:compile:content_components"
      )

      assert {:ok, named} = TailwindCompiler.compile(site.name)
      css = site_part(named, site)

      assert css =~ ".hero-inbox-arrow-down{"
      assert css =~ "mask"
      assert css =~ ".fake-star{"
    end
  end

  # A CLASS CONTENT WRITES IS IN NO TEMPLATE — a marker's `track_class="bg-[#282828]"` reaches its
  # component as an expression — so the same event answers them, and the stylesheet carries them.
  describe "TailwindCompiler.content_classes/1" do
    test "is what the stored content of the site says it writes, each once, and nothing a CSS string could not hold",
         %{site: site} do
      register_plugin(
        MishkaCmsCore.Test.Plugins.ContentComponentsNamed,
        "runtime:compile:content_components"
      )

      assert TailwindCompiler.content_classes(site.name) == [
               "bg-[#282828]",
               "data-[orientation=vertical]:h-32"
             ]
    end

    test "is nothing for a site that is not there, that nothing answers for, or while the event cannot run",
         %{site: site} do
      assert TailwindCompiler.content_classes(site.name) == []
      assert TailwindCompiler.content_classes("no-such-site") == []

      MishkaCmsCore.Test.EventCannotRun.stub!("runtime:compile:content_components")

      assert TailwindCompiler.content_classes(site.name) == []
    end

    test "each has a rule in the site's stylesheet", %{site: site} do
      on_exit(fn -> MishkaCmsCore.Runtime.States.AssetsState.delete("__shared_base__", "css") end)

      assert {:ok, unnamed} = TailwindCompiler.compile(site.name)
      refute site_part(unnamed, site) =~ "#282828"

      register_plugin(
        MishkaCmsCore.Test.Plugins.ContentComponentsNamed,
        "runtime:compile:content_components"
      )

      assert {:ok, named} = TailwindCompiler.compile(site.name)
      css = site_part(named, site)

      assert css =~ ~S(.bg-\[\#282828\]{background-color:#282828})
      assert css =~ ~S(.data-\[orientation\=vertical\]\:h-32[data-orientation=vertical]{height:)
      refute css =~ "color:red"
    end

    test "each has a rule in a draft's preview stylesheet", %{site: site} do
      on_exit(fn -> MishkaCmsCore.Runtime.States.AssetsState.delete("__shared_base__", "css") end)

      register_plugin(
        MishkaCmsCore.Test.Plugins.ContentComponentsNamed,
        "runtime:compile:content_components"
      )

      assert {:ok, css} =
               TailwindCompiler.compile_preview(
                 site.name,
                 "preview-classes-#{System.unique_integer([:positive])}",
                 "draft",
                 ~s(<div class="p-1"></div>)
               )

      [_shared, own] = String.split(css, "/* Preview: ", parts: 2)

      assert own =~ ~S(.bg-\[\#282828\])
    end
  end

  # THE ATTRIBUTES A COMPONENT TAKES A CLASS STRING IN are the ones it declares `examples` for and
  # no `values` — read off the components the site reaches, its own hiding a global one.
  describe "open_attrs/2 and site_classes/2" do
    @open_attrs [
      %{
        "name" => "size",
        "type" => "string",
        "opts" => %{"default" => "small", "examples" => ["small", "large"]}
      },
      %{
        "name" => "color",
        "type" => "string",
        "opts" => %{"default" => "base", "values" => ["base", "dark"]}
      },
      %{"name" => "title", "type" => "string", "opts" => %{"default" => nil}},
      %{"name" => "class", "type" => "any", "opts" => %{"default" => nil}}
    ]

    test "name the attributes declaring examples and no values, of the site's own and global components",
         %{site: site, n: n} do
      note!(site, "open-#{n}", attrs: @open_attrs)
      note!(nil, "global-open-#{n}", attrs: @open_attrs)
      note!(site, "closed-#{n}")

      assert ContentComponents.open_attrs(
               ["open-#{n}", "global-open-#{n}", "closed-#{n}", "nothing-#{n}"],
               site.id
             ) == %{"open-#{n}" => ["size"], "global-open-#{n}" => ["size"]}

      assert ContentComponents.open_attrs([], site.id) == %{}
    end

    test "a site's own component hides the global one of its name", %{site: site, n: n} do
      note!(nil, "shared-#{n}", attrs: @open_attrs)
      note!(site, "shared-#{n}")

      assert ContentComponents.open_attrs(["shared-#{n}"], site.id) == %{}
      assert ContentComponents.open_attrs(["shared-#{n}"], nil) == %{"shared-#{n}" => ["size"]}
    end

    test "read a marker's open attribute as classes, and leave the rest of it out", %{
      site: site,
      n: n
    } do
      note!(site, "open-#{n}", attrs: @open_attrs)

      html =
        ~s(<p class="text-sm">x</p>) <>
          ~s([[component open-#{n} size="leading-5 py-2" color="dark" title="Hidden block" class="ml-1" /]])

      assert ContentComponents.site_classes(html, site.id) == [
               "text-sm",
               "ml-1",
               "leading-5",
               "py-2"
             ]

      assert ContentComponents.site_classes(nil, site.id) == []
    end
  end

  defp site_part(css, site) do
    [_shared, own] = String.split(css, "/* Site: #{site.name} */", parts: 2)
    own
  end

  describe "embeddable/2 — what the editor offers" do
    test "lists the site's active components and the global ones, with what a marker sets", %{
      site: site,
      n: n
    } do
      note!(site, "pick-own-#{n}",
        examples: [~s(<.component component_name="pick-own-#{n}" title="Hi" />)]
      )

      note!(nil, "pick-shared-#{n}")
      note!(site, "pick-off-#{n}", active: false)
      other = site!("content-elsewhere-#{n}")
      note!(other, "pick-theirs-#{n}")

      create_component!(
        name: "pick-drawer-#{n}",
        site_id: site.id,
        active: true,
        template: ~s(<div><.rich_content html={@body} /></div>),
        attrs: [%{"name" => "body", "type" => "string", "opts" => %{"default" => ""}}]
      )

      master = create_user_with_permissions!(["admin:dashboard:*"])

      assert {:ok, entries} = ContentComponents.embeddable(master, site.id)
      names = entries |> Enum.map(& &1.name) |> Enum.filter(&String.ends_with?(&1, "-#{n}"))

      assert Enum.sort(names) == Enum.sort(["pick-own-#{n}", "pick-shared-#{n}"])

      own = Enum.find(entries, &(&1.name == "pick-own-#{n}"))

      assert own.inner_block
      refute own.global
      assert Enum.map(own.attrs, & &1.name) == ["title", "count", "open", "size"]
      assert Enum.find(own.attrs, &(&1.name == "size")).values == ["small", "large"]
      assert own.examples == [~s(<.component component_name="pick-own-#{n}" title="Hi" />)]

      assert Enum.map(own.attrs, &{&1.name, &1.group, &1.media}) == [
               {"title", "Content", false},
               {"count", "Properties", false},
               {"open", "Behavior", false},
               {"size", "Layout", false}
             ]
    end

    test "says which attributes hold a picture or a video, the page builder's way", %{
      site: site,
      n: n
    } do
      note!(site, "pick-picture-#{n}",
        attrs:
          for name <- ~w(image src poster alt caption) do
            %{"name" => name, "type" => "string", "opts" => %{}}
          end
      )

      master = create_user_with_permissions!(["admin:dashboard:*"])
      {:ok, entries} = ContentComponents.embeddable(master, site.id)
      picture = Enum.find(entries, &(&1.name == "pick-picture-#{n}"))

      assert for(%{media: true, name: name} <- picture.attrs, do: name) == ~w(image src poster)
    end

    test "a site user is offered its own site's and the global ones", %{site: site, n: n} do
      note!(site, "mine-#{n}")
      note!(nil, "ours-#{n}")
      other = site!("content-neighbour-#{n}")
      note!(other, "not-mine-#{n}")

      user = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      assert {:ok, entries} = ContentComponents.embeddable(user, site.id)
      names = entries |> Enum.map(& &1.name) |> Enum.filter(&String.ends_with?(&1, "-#{n}"))

      assert Enum.sort(names) == Enum.sort(["mine-#{n}", "ours-#{n}"])

      assert {:ok, theirs} = ContentComponents.embeddable(user, other.id)
      refute Enum.any?(theirs, &(&1.name == "not-mine-#{n}"))
    end

    test "with no site, the global ones alone", %{site: site, n: n} do
      note!(site, "local-#{n}")
      note!(nil, "everywhere-#{n}")
      master = create_user_with_permissions!(["admin:dashboard:*"])

      assert {:ok, entries} = ContentComponents.embeddable(master, nil)
      names = entries |> Enum.map(& &1.name) |> Enum.filter(&String.ends_with?(&1, "-#{n}"))

      assert names == ["everywhere-#{n}"]
    end
  end
end
