# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.PaletteEntryTest do
  @moduledoc """
  The extension seam for the palette (§22): a component that cannot be a stored template registers
  as a descriptor on `builder:components` and appears alongside the database ones.

  The registry conventions are asserted here rather than assumed — seeded with core (never `[]`),
  first declaration wins, and the module-call whitelist that keeps the editor from being talked into
  emitting a call to a module nobody registered.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Builder.PaletteEntry
  alias MishkaCmsCore.Runtime.PageBuilder.Fields
  alias MishkaCmsCore.Runtime.PageBuilder.Presets
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Wizard
  alias MishkaCmsCore.Test.Plugins.BuilderComponentsPlugin
  alias MishkaInstaller.Event.{Event, EventHandler}

  describe "the descriptor" do
    test "derives a key and a label from the name" do
      entry = PaletteEntry.new!(%{name: "latest-posts"})

      assert entry.key == "latest-posts"
      assert entry.label == "Latest Posts"
      assert entry.type == "general"
      assert entry.examples == []
    end

    test "an explicit key and label win" do
      entry = PaletteEntry.new!(%{name: "x", key: "custom", label: "Nice Name"})

      assert entry.key == "custom"
      assert entry.label == "Nice Name"
    end

    test "a nameless descriptor is refused" do
      assert {:error, _errors} = PaletteEntry.build(%{label: "No name"})
    end

    test "new!/1 raises so a malformed declaration fails the build, not the page" do
      assert_raise ArgumentError, ~r/invalid palette entry/, fn ->
        PaletteEntry.new!(%{label: "No name"})
      end
    end
  end

  describe "template/2" do
    test "a tenant component is bound to the page's own site" do
      entry = PaletteEntry.new!(%{name: "chelekom-card", global?: false})

      assert PaletteEntry.template(entry, "acme") ==
               ~s(<.component component_name="chelekom-card" site="acme" />)
    end

    test "a site-less scope falls back to Global" do
      entry = PaletteEntry.new!(%{name: "chelekom-card", global?: false})
      assert PaletteEntry.template(entry, nil) =~ ~s(site="Global")
    end

    # The compiled module's name is hashed from this attribute. Binding a global component to the
    # page's site named a module nobody ever built, so dropping one from the palette painted the
    # runtime's red "failed to render" over a component that works.
    test "a global component stays bound to Global whatever page it is dropped on" do
      entry = PaletteEntry.new!(%{name: "global-footer"})

      assert entry.global?
      assert PaletteEntry.template(entry, "acme") =~ ~s(site="Global")
    end

    # Reading an assign that was never set raises `KeyError`, and inside the canvas that takes the
    # LiveView down — the author drops a component and gets a 500 page. A required attribute with no
    # default and a required slot are both assigns nothing supplies, so both are seeded.
    test "a required attribute with no default is seeded rather than left to raise" do
      entry =
        PaletteEntry.new!(%{
          name: "chelekom-video",
          attrs: [
            %{"name" => "poster", "type" => "string", "opts" => %{"required" => true}},
            %{"name" => "width", "type" => "string", "opts" => %{"default" => "full"}}
          ]
        })

      template = PaletteEntry.template(entry, "acme")

      assert template =~ ~s(poster="")

      # An attribute the component already defaults is left alone, so its own default keeps applying.
      refute template =~ "width="
    end

    # A MAP ATTRIBUTE MUST BE SEEDED WITH A MAP. Every non-scalar type fell through to the string
    # clause, so a required `map` was written `flash="example"` and the component's own
    # `Phoenix.Flash.get(@flash, :info)` called `Map.get/2` on a binary — a BadMapError that took the
    # preview LiveView down and turned the wizard tab into a 500. `chelekom-flash-group` was the one
    # component in the kit that declares one, and any kit with another would have done the same.
    test "a required map attribute is seeded as a map expression, never a quoted string" do
      entry =
        PaletteEntry.new!(%{
          name: "chelekom-flash-group",
          attrs: [%{"name" => "flash", "type" => "map", "opts" => %{"required" => true}}]
        })

      assert PaletteEntry.seeded(entry, [], :blank) == " flash={%{}}"

      refute PaletteEntry.seeded(entry, [], :blank) =~ ~s(flash="),
             "a string here is a BadMapError the moment the component reads it"
    end

    # An empty map is valid and renders NOTHING, which is indistinguishable from the crash it
    # replaced. A preview has no author to fill it in, so `flash` — a Phoenix convention, not a kit's
    # — is seeded with the string-keyed messages `Phoenix.Flash.get/2` actually reads.
    test "a preview seeds flash with messages it can render" do
      entry =
        PaletteEntry.new!(%{
          name: "chelekom-flash-group",
          attrs: [%{"name" => "flash", "type" => "map", "opts" => %{"required" => true}}]
        })

      seeded = PaletteEntry.seeded(entry, [], :preview)

      assert seeded =~ ~s("info" =>)
      assert seeded =~ ~s("error" =>)
    end

    # A list attribute has the same hole: `sections=""` where the template does `for s <- @sections`.
    test "a required list attribute is seeded as a list expression" do
      entry =
        PaletteEntry.new!(%{
          name: "chelekom-accordion",
          attrs: [%{"name" => "sections", "type" => "list", "opts" => %{"required" => true}}]
        })

      assert PaletteEntry.seeded(entry, [], :blank) == " sections={[]}"
    end

    # A value the component actually has a clause for beats a neutral literal it may fall through on.
    test "a seeded attribute takes the first value it declares" do
      entry =
        PaletteEntry.new!(%{
          name: "chelekom-alert",
          attrs: [
            %{
              "name" => "kind",
              "type" => "atom",
              "opts" => %{"required" => true, "values" => ["natural", "danger"]}
            }
          ]
        })

      assert PaletteEntry.template(entry, "acme") =~ "kind={:natural}"
    end

    test "a required slot is opened so its assign exists" do
      entry =
        PaletteEntry.new!(%{
          name: "chelekom-video",
          slots: [
            %{
              "name" => "source",
              "opts" => %{"required" => true},
              "attrs" => [%{"name" => "src", "type" => "string", "opts" => %{"required" => true}}]
            },
            %{"name" => "track", "opts" => %{}, "attrs" => []}
          ]
        })

      template = PaletteEntry.template(entry, "acme")

      # PLACEMENT leaves it blank on purpose: the inspector marks it "Required" and the save refuses
      # until the author fills it. Only the wizard's PREVIEW seeds a real placeholder — see
      # `seeded/3` with `:preview`.
      assert template =~ ~s(<:source src=""></:source>)
      # An optional slot already arrives as `[]`, so opening one would only add markup to delete.
      refute template =~ "<:track"
      assert template =~ "</.component>"
    end

    test "a component with nothing to seed stays self-closing" do
      entry = PaletteEntry.new!(%{name: "chelekom-card", attrs: [], slots: []})

      assert PaletteEntry.template(entry, "acme") =~ " />"
    end

    test "a descriptor with a render ref becomes a module call" do
      entry = PaletteEntry.new!(%{name: "latest-posts", render: {MishkaBlogWeb.Latest, :render}})

      assert PaletteEntry.template(entry, "acme") == "<MishkaBlogWeb.Latest.render />"
      assert PaletteEntry.module_component?(entry)
    end

    test "a database component is not a module component" do
      refute PaletteEntry.module_component?(PaletteEntry.new!(%{name: "card"}))
    end
  end

  # Another kit's contact form: its one outer element is that kit's form component, and its `for` is
  # optional. Only the palette says the component it calls owns a form.
  defp acme_forms do
    [
      PaletteEntry.new!(%{
        name: "acme-form",
        attrs: [%{"name" => "for", "type" => "any", "opts" => %{"required" => true}}],
        slots: [%{"name" => "inner_block"}],
        template: ~S|<.form :let={f} for={@for}>{render_slot(@inner_block, f)}</.form>|
      }),
      PaletteEntry.new!(%{
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
          ~S|<.component component_name="acme-form" site="Global" :let={f} for={@for} class={@variant}>{render_slot(@inner_block, f)}</.component>|
      })
    ]
  end

  describe "seeding a form that calls another kit's form" do
    test "is seeded an empty map when the palette says what it calls" do
      [_form, contact] = palette = acme_forms()

      assert PaletteEntry.template(contact, nil, palette) =~ "for={%{}}"
      assert PaletteEntry.seeded(contact, [], :preview, palette) =~ "for={%{}}"
      refute PaletteEntry.template(contact, nil) =~ "for={%{}}"
    end

    test "the placed component is a form to the editor, holding a form's data" do
      [_form, contact] = palette = acme_forms()
      tree = contact |> PaletteEntry.template(nil, palette) |> Tree.parse!()
      placed = tree |> Tree.walk() |> Enum.find(&(&1.kind == :component))

      assert Fields.form_node?(placed, Fields.roles([placed], palette))
      assert Tree.Node.attr(placed, "for") == {:expr, "%{}"}
    end

    test "the wizard and the site's preset seed it the same way" do
      [_form, contact] = palette = acme_forms()

      assert Wizard.compose(contact, %{}, nil, :preview, palette) =~ "for={%{}}"
      assert Wizard.compose(contact, %{"variant" => "boxed"}, nil, :blank, palette) =~ "for={%{}}"
      assert Presets.template(contact, nil, %{}, palette) =~ "for={%{}}"

      assert Presets.template(contact, nil, %{"acme-contact" => %{"variant" => "boxed"}}, palette) =~
               "for={%{}}"

      assert Presets.template(contact, nil, nil, palette) =~ "for={%{}}"
    end
  end

  describe "the serialization whitelist" do
    setup do
      entries = [
        PaletteEntry.new!(%{name: "a", render: {MishkaBlogWeb.Latest, :render}}),
        PaletteEntry.new!(%{name: "b"})
      ]

      %{whitelist: PaletteEntry.whitelist(entries)}
    end

    test "only modules a descriptor named are in it", %{whitelist: whitelist} do
      assert MapSet.to_list(whitelist) == [MishkaBlogWeb.Latest]
    end

    test "a template calling a registered module passes", %{whitelist: whitelist} do
      assert PaletteEntry.permitted?("<MishkaBlogWeb.Latest.render />", whitelist)
    end

    # A fully-qualified call in a template is arbitrary code at compile time.
    test "a template calling anything else is refused", %{whitelist: whitelist} do
      refute PaletteEntry.permitted?("<System.Evil.run />", whitelist)
      refute PaletteEntry.permitted?(~s(<div><File.rm_rf /></div>), whitelist)
    end

    test "plain markup and wrapper components are unaffected", %{whitelist: whitelist} do
      assert PaletteEntry.permitted?(~s(<div class="x"><p>hi</p></div>), whitelist)
      assert PaletteEntry.permitted?(~s(<.component component_name="card" site="a" />), whitelist)
    end
  end

  describe "builder:components — the registry" do
    setup do
      Process.register(self(), :__builder_palette_probe__)

      {:ok, _} =
        Event.write(%{
          name: BuilderComponentsPlugin,
          event: "builder:components",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("builder:components", :start, false)
      on_exit(fn -> Event.unregister(:name, BuilderComponentsPlugin, false) end)
      :ok
    end

    test "a plugin's descriptor joins the core's seeded palette" do
      seed = [%{key: "core-card", name: "core-card", type: "layout", priority: 50}]

      collected = Events.collect(:components, seed)
      names = Enum.map(collected, & &1.name)

      assert "core-card" in names
      assert "latest-posts" in names
    end

    test "the plugin receives the core's entries, it does not replace them" do
      Events.collect(:components, [
        %{key: "a", name: "a", priority: 50},
        %{key: "b", name: "b", priority: 50}
      ])

      assert_receive {:builder_components, 2}, 2000
    end

    # THE ONE THAT WAS MISSING, and the reason a contributed component took the editor down. Every
    # test above asserts the descriptor reaches the list; none of them drew it. The palette asked
    # each card `entry[:has_examples?]`, which a plain map answers and a `%PaletteEntry{}` — the
    # documented shape for a contribution — raises on, because structs have no `Access`.
    test "and the palette can actually draw it" do
      entry = BuilderComponentsPlugin.entry()

      assert PaletteEntry.optional(entry, :has_examples?) == nil
      assert PaletteEntry.optional(entry, :offers_options?) == nil
      assert PaletteEntry.optional(entry, :kit) == nil
    end

    test "while the core's own entries still answer what they carry" do
      core = %{key: "core-card", name: "core-card", has_examples?: true, kit: "Chelekom"}

      assert PaletteEntry.optional(core, :has_examples?) == true
      assert PaletteEntry.optional(core, :kit) == "Chelekom"
    end

    # `sidebar:menus` convention: a plugin may add but never redefine a core entry.
    test "the first declaration of a key wins" do
      seed = [%{key: "latest-posts", name: "latest-posts", type: "core-wins", priority: 1}]

      collected = Events.collect(:components, seed)
      entry = Enum.find(collected, &(&1.name == "latest-posts"))

      assert entry.type == "core-wins"
      assert length(Enum.filter(collected, &(&1.name == "latest-posts"))) == 1
    end

    test "entries come back sorted by priority" do
      seed = [%{key: "z", name: "z", priority: 90}]
      collected = Events.collect(:components, seed)

      # The plugin declares priority 10, so it sorts ahead of the seed's 90.
      assert Enum.map(collected, & &1.name) == ["latest-posts", "z"]
    end
  end
end
