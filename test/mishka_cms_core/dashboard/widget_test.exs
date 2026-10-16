# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dashboard.WidgetTest do
  @moduledoc """
  Real tests for the dashboard widget module: the GuardedStruct descriptor validates its required
  fields, `arrange/2` applies the per-user layout (order / hidden / added) over the registered
  defaults, `card/1` actually renders a widget by dispatching to its `component`, and a widget's
  SETTINGS round-trip through `MishkaCmsCore.Settings` as per-user rows (`config/3` / `set_config/4`)
  rather than through the layout blob they used to live in.

  Settings hit the durable store, so this case is `DataCase`-backed: the ETS settings cache is
  process-global (not sandboxed), so each test refreshes it from the (rolled-back) database on exit,
  the same way `MishkaCmsCore.SettingsTest` does.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  setup do
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    :ok
  end

  defp widget(id, opts \\ []),
    do:
      struct(
        Widget,
        Keyword.merge(
          [id: id, title: id, component: {MishkaCmsCore.Dashboard.Widgets.SiteOverview, :render}],
          opts
        )
      )

  # A viewer is only ever an id to the settings store, so a bare map is a faithful stand-in and
  # keeps these tests off the users table.
  defp user, do: %{id: Ecto.UUID.generate()}

  describe "builder/1" do
    test "builds a valid widget with defaults" do
      assert {:ok, %Widget{id: "x", title: "X", type: :function, size: 1, category: "general"}} =
               Widget.builder(%{id: "x", title: "X", component: {Widget, :stats}})
    end

    test "rejects a missing required field" do
      assert {:error, errors} = Widget.builder(%{title: "X", component: {Widget, :stats}})
      assert is_list(errors)
    end
  end

  describe "arrange/2" do
    test "no layout keeps registered order and drops default-hidden widgets" do
      widgets = [widget("a"), widget("b", default_hidden: true), widget("c")]
      assert ["a", "c"] == Enum.map(Widget.arrange(widgets), & &1.id)
    end

    test "a layout's order and hidden win" do
      widgets = [widget("a"), widget("b"), widget("c")]
      layout = %{"order" => ["c", "a"], "hidden" => ["b"]}
      assert ["c", "a"] == Enum.map(Widget.arrange(widgets, layout), & &1.id)
    end

    test "added reveals a default-hidden widget" do
      widgets = [widget("a"), widget("b", default_hidden: true)]
      assert ["a", "b"] == Enum.map(Widget.arrange(widgets, %{"added" => ["b"]}), & &1.id)
    end

    # THE LAYOUT BLOB IS NOT A VALIDATED DOCUMENT. It is a per-user preference row an extension or a
    # half-finished migration can write anything into, and every reader of it here is `++`, `in` or
    # `Enum.find_index/2` — each of which raises on a non-list. `arrange/2` runs inside
    # `Home.Index.mount/3`, so a raise is not one dead card: it is HTTP 500 on /admin/dashboard with
    # nothing rendered, for that user, until somebody edits the database. A string under "hidden"
    # did exactly that.
    test "a layout of the wrong shape degrades instead of taking the dashboard down" do
      widgets = [widget("a"), widget("b"), widget("c", default_hidden: true)]

      hostile = [
        %{"hidden" => "everything"},
        %{"added" => "everything"},
        %{"order" => "everything"},
        %{"hidden" => 42, "added" => nil, "order" => %{"a" => 1}},
        %{"order" => ["a", 42, nil, "no-such-widget"]},
        "not a map at all",
        nil
      ]

      for layout <- hostile do
        assert ["a", "b"] == Enum.map(Widget.arrange(widgets, layout), & &1.id),
               "arrange/2 mishandled #{inspect(layout)}"
      end
    end
  end

  describe "span/2 — a width that is not a width" do
    # `min/2` and `max/2` compare ANY two terms rather than raising, and every number sorts below
    # every binary, so `min("banana", 6)` is 6: a junk span did not fail, it silently claimed the
    # full row. Falling back to the widget's declared size is the only answer that is not a guess.
    test "a non-integer span falls back to the widget's declared size" do
      w = widget("a", size: 2)

      for junk <- ["banana", nil, %{}, [6], "6"] do
        assert Widget.span(w, %{"spans" => %{"a" => junk}}) == 2,
               "span/2 accepted #{inspect(junk)}"
      end
    end

    test "an integer span is still honoured, and still clamped" do
      w = widget("a", size: 2)

      assert Widget.span(w, %{"spans" => %{"a" => 4}}) == 4
      assert Widget.span(w, %{"spans" => %{"a" => 99}}) == 6
      assert Widget.span(w, %{"spans" => %{"a" => -7}}) == 1
    end

    test "a spans value of the wrong shape is ignored" do
      w = widget("a", size: 3)

      assert Widget.span(w, %{"spans" => "banana"}) == 3
      assert Widget.span(w, "not a map") == 3
    end
  end

  describe "available/2" do
    test "returns the permitted widgets not currently shown" do
      widgets = [widget("a"), widget("b"), widget("c")]
      assert ["b"] == Enum.map(Widget.available(widgets, %{"hidden" => ["b"]}), & &1.id)
    end

    test "default-hidden widgets are available until added" do
      widgets = [widget("a"), widget("b", default_hidden: true)]
      assert ["b"] == Enum.map(Widget.available(widgets), & &1.id)
      assert [] == Widget.available(widgets, %{"added" => ["b"]})
    end
  end

  describe "layout transforms" do
    test "hide/2 hides a widget and clears it from added" do
      assert %{"hidden" => ["a"], "added" => []} = Widget.hide(%{"added" => ["a"]}, "a")
    end

    test "add/2 reveals a widget and appends it to the order" do
      layout = Widget.add(%{"hidden" => ["a"], "order" => ["x"]}, "a")
      assert layout["hidden"] == []
      assert "a" in layout["added"]
      assert layout["order"] == ["x", "a"]
    end

    test "reorder/2 adopts the dragged id list and drops junk entries" do
      widgets = [widget("a"), widget("b"), widget("c")]
      layout = Widget.reorder(%{}, ["c", "a", 42, "b"])
      assert layout["order"] == ["c", "a", "b"]
      assert ["c", "a", "b"] == Enum.map(Widget.arrange(widgets, layout), & &1.id)
    end

    test "add_at/4 reveals a widget and drops it at the given slot" do
      widgets = [widget("a"), widget("b"), widget("c", default_hidden: true)]
      layout = Widget.add_at(%{}, widgets, "c", 1)
      assert ["a", "c", "b"] == Enum.map(Widget.arrange(widgets, layout), & &1.id)
    end

    test "set_span/3 layers the user's width over the registered size" do
      wide = widget("a", size: 2)
      assert Widget.span(wide, %{}) == 2
      layout = Widget.set_span(%{}, "a", 3)
      assert Widget.span(wide, layout) == 3
      assert Widget.span(widget("b"), layout) == 1
    end

    test "span/2 clamps an out-of-range registered size to the grid" do
      assert Widget.span(widget("a", size: 9), %{}) == 6
      assert Widget.span(widget("a", size: 0), %{}) == 1
    end
  end

  describe "permission — one name or a list" do
    test "builder/1 accepts a single permission string" do
      assert {:ok, %{permission: "admin:dashboard:*"}} =
               Widget.builder(%{
                 id: "w",
                 title: "W",
                 component: {Widget, :stats},
                 permission: "admin:dashboard:*"
               })
    end

    test "builder/1 accepts a list of permissions" do
      assert {:ok, %{permission: ["admin:dashboard:blog:post", "admin:dashboard:*"]}} =
               Widget.builder(%{
                 id: "w",
                 title: "W",
                 component: {Widget, :stats},
                 permission: ["admin:dashboard:blog:post", "admin:dashboard:*"]
               })
    end

    test "a widget naming no permission is open to anyone" do
      assert {:ok, %{permission: nil}} =
               Widget.builder(%{id: "w", title: "W", component: {Widget, :stats}})
    end

    test "settings_definitions/1 carries the declared permission through, whichever shape" do
      setting = %{key: "count", type: :integer, label: "Rows", default: 3, min: 1, max: 9}

      one = widget("a", permission: "admin:dashboard:blog:post", config: [setting])
      many = widget("b", permission: ["admin:dashboard:blog:post", "x:y"], config: [setting])

      assert [%{permission: "admin:dashboard:blog:post"}] = Widget.settings_definitions(one)

      assert [%{permission: ["admin:dashboard:blog:post", "x:y"]}] =
               Widget.settings_definitions(many)
    end
  end

  describe "config/3 and set_config/4" do
    defp configurable(overrides \\ []) do
      widget(
        Keyword.get(overrides, :id, "cfg"),
        Keyword.merge(
          [
            settings_category: "blog",
            config: [
              %{key: "count", type: :integer, label: "Rows", default: 6, min: 1, max: 12},
              %{key: "avatars", type: :boolean, label: "Avatars", default: true},
              %{
                key: "sort",
                type: :select,
                label: "Sort",
                default: "recent",
                options: [{"Recent", "recent"}, {"Viewed", "viewed"}]
              }
            ]
          ],
          Keyword.drop(overrides, [:id])
        )
      )
    end

    test "setting_key/2 is one stable, namespaced key per widget setting" do
      assert Widget.setting_key(configurable(), "count") == "dashboard.widget.cfg.count"
      assert Widget.setting_key("cfg", "count") == "dashboard.widget.cfg.count"
    end

    test "config/3 returns every declared default when the user has never customised" do
      assert Widget.config(configurable(), user()) == %{
               "count" => 6,
               "avatars" => true,
               "sort" => "recent"
             }
    end

    test "config/3 layers the user's saved value over the default" do
      me = user()
      assert {:ok, 3} = Widget.set_config(me, configurable(), "count", "3")

      assert %{"count" => 3, "avatars" => true} = Widget.config(configurable(), me)
    end

    test "a widget that declares nothing gets an empty config" do
      assert Widget.config(widget("plain"), user(), %{"config" => %{"plain" => %{"count" => 9}}}) ==
               %{}
    end

    test "set_config/4 stores a coerced integer under the widget's own settings key" do
      me = user()
      w = configurable()

      assert {:ok, 9} = Widget.set_config(me, w, "count", "9")
      assert Settings.get_user(Widget.setting_key(w, "count"), me.id) == 9
    end

    test "set_config/4 clamps an integer to the declared bounds" do
      me = user()
      w = configurable()

      assert {:ok, 12} = Widget.set_config(me, w, "count", "99")
      assert %{"count" => 12} = Widget.config(w, me)

      assert {:ok, 1} = Widget.set_config(me, w, "count", "0")
      assert %{"count" => 1} = Widget.config(w, me)
    end

    test "set_config/4 reads a checkbox's on/false the way the browser posts it" do
      me = user()
      w = configurable()

      assert {:ok, true} = Widget.set_config(me, w, "avatars", "on")
      assert %{"avatars" => true} = Widget.config(w, me)

      assert {:ok, false} = Widget.set_config(me, w, "avatars", "false")
      assert %{"avatars" => false} = Widget.config(w, me)
    end

    test "set_config/4 keeps a select on the declared options" do
      me = user()
      w = configurable()

      assert {:ok, "viewed"} = Widget.set_config(me, w, "sort", "viewed")
      assert %{"sort" => "viewed"} = Widget.config(w, me)

      assert Widget.set_config(me, w, "sort", "'; DROP TABLE --") == :error
      assert %{"sort" => "viewed"} = Widget.config(w, me)
    end

    test "set_config/4 refuses anything the widget did not declare, and writes nothing" do
      me = user()
      w = configurable()

      assert Widget.set_config(me, w, "count", "abc") == :error
      assert Widget.set_config(me, w, "unknown_key", "1") == :error
      assert Widget.set_config(me, widget("plain"), "count", "1") == :error

      assert Settings.get_user(Widget.setting_key(w, "count"), me.id) == nil
      assert Settings.get_user(Widget.setting_key(w, "unknown_key"), me.id) == nil
      assert %{"count" => 6} = Widget.config(w, me)
    end

    test "set_config/4 without a user writes nothing" do
      assert Widget.set_config(nil, configurable(), "count", "4") == :error
    end

    test "set_config/4 leaves other widgets' settings alone" do
      me = user()
      other_widget = configurable(id: "other")

      assert {:ok, 2} = Widget.set_config(me, other_widget, "count", "2")
      assert {:ok, 4} = Widget.set_config(me, configurable(), "count", "4")

      assert %{"count" => 2} = Widget.config(other_widget, me)
      assert %{"count" => 4} = Widget.config(configurable(), me)
    end

    test "two users never share a value — each reads only their own" do
      w = configurable()
      me = user()
      you = user()

      assert {:ok, 2} = Widget.set_config(me, w, "count", "2")
      assert {:ok, 11} = Widget.set_config(you, w, "count", "11")

      assert %{"count" => 2} = Widget.config(w, me)
      assert %{"count" => 11} = Widget.config(w, you)

      # And the un-namespaced key stays empty: nothing about this leaks to a global/site value.
      assert Settings.get(Widget.setting_key(w, "count")) == nil
      assert %{"count" => 6} = Widget.config(w, user())
    end

    test "config/3 re-validates a stored value rather than trusting it" do
      me = user()
      w = configurable()

      # What a hand-edit (or the settings page, which knows no min/max) can leave behind.
      Settings.put_user(Widget.setting_key(w, "count"), 999, me.id)
      Settings.put_user(Widget.setting_key(w, "sort"), "evil", me.id)

      assert %{"count" => 12, "sort" => "recent"} = Widget.config(w, me)
    end

    test "config/3 falls back to the pre-Settings layout blob until the setting is saved" do
      me = user()
      w = configurable()
      legacy = %{"config" => %{"cfg" => %{"count" => 3, "sort" => "viewed"}}}

      assert %{"count" => 3, "sort" => "viewed"} = Widget.config(w, me, legacy)

      # The blob is re-validated too, exactly like a stored row.
      assert %{"count" => 12} =
               Widget.config(w, me, %{"config" => %{"cfg" => %{"count" => 999}}})

      # And the first real save wins over it, for good.
      assert {:ok, 5} = Widget.set_config(me, w, "count", "5")
      assert %{"count" => 5, "sort" => "viewed"} = Widget.config(w, me, legacy)
    end

    test "config/3 survives a legacy layout whose config is not a map" do
      assert %{"count" => 6} = Widget.config(configurable(), user(), %{"config" => "junk"})
      assert %{"count" => 6} = Widget.config(configurable(), user(), %{})
    end

    test "config/3 with no user is just the declared defaults" do
      assert %{"count" => 6, "avatars" => true} = Widget.config(configurable(), nil)
    end

    test "reset_config/2 puts every setting back to its declared default" do
      me = user()
      w = configurable()

      assert {:ok, 11} = Widget.set_config(me, w, "count", "11")
      assert {:ok, false} = Widget.set_config(me, w, "avatars", "false")

      assert :ok = Widget.reset_config(me, w)

      assert Widget.config(w, me) == %{"count" => 6, "avatars" => true, "sort" => "recent"}
    end
  end

  describe "settings_definitions/1" do
    test "one per declared setting, in the widget's own settings tab, per user" do
      w = configurable(permission: "admin:dashboard:*")

      assert [count, avatars, sort] = Widget.settings_definitions(w)

      assert count.key == "dashboard.widget.cfg.count"
      assert count.type == :integer
      assert count.default == 6
      assert count.category == "blog"
      assert count.group == "Dashboard widgets"
      assert count.scope == :user
      assert count.source == :plugin
      assert count.permission == "admin:dashboard:*"
      assert MishkaCmsCore.Settings.text(count.label) =~ "Rows"

      assert avatars.type == :boolean
      assert sort.options == ["recent", "viewed"]
    end

    test "falls back to the descriptor's category when no settings tab is named" do
      w = configurable(settings_category: nil)
      assert [%{category: "general"} | _] = Widget.settings_definitions(w)
    end

    test "a widget that declares nothing registers nothing" do
      assert Widget.settings_definitions(widget("plain")) == []
    end

    test "an unsupported declaration is skipped rather than registered" do
      w = widget("odd", config: [%{key: "x", type: :colour, label: "X", default: "red"}])

      assert Widget.settings_definitions(w) == []
      assert Widget.config(w, user()) == %{"x" => "red"}
    end
  end

  describe "stat/1" do
    test "writes a count in the reader's digits, and anything else as it is" do
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      on_exit(fn -> Gettext.put_locale(MishkaCmsCore.Gettext, "en") end)

      assert render_component(&Widget.stat/1, label: "Users", value: 1284) =~ "۱٬۲۸۴"
      assert render_component(&Widget.stat/1, label: "Users", value: "—") =~ "—"
    end
  end

  describe "card/1" do
    test "shows a skeleton while loading" do
      html =
        render_component(&Widget.card/1, widget: widget("x"), state: :loading, current_user: nil)

      assert html =~ "animate-pulse"
    end

    test "shows the failure placeholder on error" do
      html =
        render_component(&Widget.card/1,
          widget: widget("x"),
          state: {:error, :boom},
          current_user: nil
        )

      assert html =~ "could not load"
    end

    test "renders the widget from its loaded data when ok" do
      html =
        render_component(&Widget.card/1,
          widget: widget("x"),
          state:
            {:ok,
             %{
               view: :master,
               total: 3,
               active: 2,
               inactive: 1,
               api_only: 1,
               phoenix_only: 1,
               hybrid: 1,
               bundle: %{css: 151, js: 75}
             }},
          current_user: nil
        )

      assert html =~ "Sites"
      assert html =~ "3"
    end
  end

  # `phx-update="ignore"` means the panel is never patched again, so a value the server clamps would
  # sit on screen for the rest of the session while the card showed the clamped one. The number field
  # is bounded on the client as well, which is what keeps the two in step.
  describe "a number setting in the gear panel" do
    defp number_field do
      render_component(&Widget.config_control/1,
        id: "recent-posts",
        settings: [
          %{key: "count", type: :integer, label: "Posts to show", min: 1, max: 12, default: 5}
        ],
        values: %{"count" => 12}
      )
    end

    test "carries the bounds the server casts against" do
      html = number_field()

      assert html =~ ~s(min="1")
      assert html =~ ~s(max="12")
    end

    test "and a hook to hold the field to them" do
      assert number_field() =~ ~s(phx-hook="NumberBounds")
    end
  end
end
