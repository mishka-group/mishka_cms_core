defmodule MishkaCmsCore.SidebarTest do
  @moduledoc """
  The sidebar registry: what the core declares, what a plugin may add to it, what a given admin is
  allowed to see, and how an admin's Settings rearrange it.

  `MishkaCmsCoreWeb.Test.SidebarPermissionsTest` covers the same filtering through the rendered
  chrome. Neither asserts anything about page access — the sidebar decides what is SHOWN, and the
  page behind a link decides for itself who may open it.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCore.Sidebar.{Group, Item}
  alias MishkaCmsCoreWeb.Live.Admin.Builder.{BuilderLive, CanvasLive}
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.{Account, Runtime}

  # Both cache writes are ETS-only, so they never touch the sandboxed connection — but ETS outlives
  # the test, so every override has to be taken back out again.
  defp override(key, value) do
    SettingsState.put(nil, key, value)
    on_exit(fn -> SettingsState.delete(nil, key) end)
  end

  defp labels(entries), do: Enum.map(entries, & &1.label)

  defp group(menu, key), do: Enum.find(menu.main, &(is_struct(&1, Group) and &1.key == key))

  describe "the core menu" do
    test "declares the console's own navigation, so a CMS with no plugin is still navigable" do
      %{groups: groups, items: items} = Sidebar.core_menu()

      assert Enum.map(groups, & &1.key) == ["runtime", "account", "plugins"]
      assert "home" in Enum.map(items, & &1.key)
      assert "settings" in Enum.map(items, & &1.key)
    end

    test "pins Settings to the footer and leaves everything else in the scrolling nav" do
      %{items: items} = Sidebar.core_menu()

      assert Enum.filter(items, &(&1.position == :footer)) |> labels() == ["Settings"]
    end

    test "declares an empty Plugins section — extensions fill it, the core does not name them" do
      %{items: items} = Sidebar.core_menu()

      assert Enum.filter(items, &(&1.group == "plugins")) == []
    end

    test "every core item names a permission, so no link is ungated" do
      %{items: items} = Sidebar.core_menu()

      assert Enum.all?(items, &(&1.permissions != []))
    end
  end

  describe "collect/0" do
    test "seeds the event with the core menu rather than an empty list" do
      %{groups: groups, items: items} = Sidebar.collect()

      assert Enum.map(Sidebar.core_menu().groups, & &1.key) -- Enum.map(groups, & &1.key) == []
      assert Enum.map(Sidebar.core_menu().items, & &1.key) -- Enum.map(items, & &1.key) == []
    end

    test "keeps the first declaration of a key, so a plugin cannot redefine a core entry" do
      assert %{items: items} = Sidebar.collect()
      assert Enum.uniq_by(items, & &1.key) == items
    end
  end

  describe "menu/1 — permission filtering" do
    test "a site admin sees Runtime with Sites in it, and not Account" do
      user = create_user_with_permissions!(["admin:dashboard:runtime:site"])

      menu = Sidebar.menu(user)

      assert "Sites" in labels(group(menu, "runtime").items)
      refute group(menu, "account")
    end

    test "a user admin sees Users and not Permissions, and Runtime without Sites" do
      user = create_user_with_permissions!(["admin:dashboard:user"])

      menu = Sidebar.menu(user)

      assert labels(group(menu, "account").items) == ["Users"]
      refute "Sites" in labels(group(menu, "runtime").items)
    end

    test "a permission admin sees Permissions and not Users" do
      user = create_user_with_permissions!(["admin:dashboard:permission"])

      assert labels(group(Sidebar.menu(user), "account").items) == ["Permissions"]
    end

    test "every dashboard admin sees the content lists, whatever area they hold" do
      user = create_user_with_permissions!(["admin:dashboard:blog:post"])

      assert labels(group(Sidebar.menu(user), "runtime").items) == [
               "Components",
               "Layouts",
               "Error Pages",
               "Pages",
               "Media",
               "Stylesheets",
               "JS Hooks",
               "Translations",
               "Redirects"
             ]
    end

    test "a group whose every item was filtered away is dropped with them" do
      user = create_user_with_permissions!(["admin:dashboard:blog:post"])

      menu = Sidebar.menu(user)

      refute group(menu, "account")
      assert labels(menu.main) == ["Home", "Runtime"]
      assert labels(menu.footer) == ["Settings"]
    end

    test "an API admin sees nothing: the sidebar is the dashboard's" do
      user = create_user_with_permissions!(["admin:api:*"])

      assert Sidebar.menu(user) == %{main: [], footer: []}
    end

    test "a full dashboard admin sees everything the core declares" do
      user = create_user_with_permissions!(["admin:dashboard:*"])

      menu = Sidebar.menu(user)

      assert labels(menu.main) == ["Home", "Runtime", "Account"]
      assert "Sites" in labels(group(menu, "runtime").items)
    end

    test "the star permission sees everything the core declares" do
      user = create_user_with_permissions!(["*"])

      menu = Sidebar.menu(user)

      assert labels(menu.main) == ["Home", "Runtime", "Account"]
      assert labels(menu.footer) == ["Settings"]
    end

    test "a user holding nothing sees nothing" do
      assert Sidebar.menu(create_user!()) == %{main: [], footer: []}
    end

    test "no user sees nothing — an absent actor is never treated as a permitted one" do
      assert Sidebar.menu(nil) == %{main: [], footer: []}
    end

    test "works with an already-loaded actor without reloading it" do
      user = create_user_with_permissions!(["*"])

      assert Ash.Resource.loaded?(user, :permissions)
      assert labels(Sidebar.menu(user).main) == ["Home", "Runtime", "Account"]
    end

    test "works with an actor whose permissions are not loaded" do
      user = create_user_with_permissions!(["*"])
      unloaded = Ash.get!(MishkaCmsCore.Accounts.User, user.id, authorize?: false)

      refute Ash.Resource.loaded?(unloaded, :permissions)
      assert labels(Sidebar.menu(unloaded).main) == ["Home", "Runtime", "Account"]
    end
  end

  describe "menu/1 — settings" do
    setup do
      {:ok, user: create_user_with_permissions!(["*"])}
    end

    test "an order override moves an entry", %{user: user} do
      assert labels(Sidebar.menu(user).main) == ["Home", "Runtime", "Account"]

      override(Sidebar.order_key("account"), 5)

      assert labels(Sidebar.menu(user).main) == ["Account", "Home", "Runtime"]
    end

    test "an order override reorders inside a group too", %{user: user} do
      override(Sidebar.order_key("runtime.js_hooks"), 1)

      assert group(Sidebar.menu(user), "runtime").items |> labels() |> List.first() == "JS Hooks"
    end

    test "visible: false hides an entry from everyone", %{user: user} do
      override(Sidebar.visible_key("runtime.medias"), false)

      refute "Media" in labels(group(Sidebar.menu(user), "runtime").items)
    end

    # A SITE SWITCHING AN EXTENSION OFF, which is not the same question as hiding one entry: it is
    # asked of the extension and answered for every entry the extension owns at once.
    test "an extension switched off for the site draws none of its entries", %{user: user} do
      items = [
        Item.new!(%{
          key: "shop",
          label: "Shop",
          path: "/admin/dashboard/shop",
          extension: :mishka_shop
        }),
        Item.new!(%{
          key: "shop.orders",
          label: "Orders",
          path: "/admin/dashboard/shop/orders",
          extension: :mishka_shop
        })
      ]

      assert Enum.all?(items, &Sidebar.visible_to?(&1, user, nil)),
             "an extension nobody switched off is on"

      override("mishka_shop.active", false)

      refute Enum.any?(items, &Sidebar.visible_to?(&1, user, nil)),
             "the switch left one of the extension's entries behind"
    end

    # A MASTER IS LOOKING AT A SITE TOO — the master site, which is an ordinary site with an ordinary
    # switch. Reading the global settings instead went on showing an extension to the one admin who
    # had just turned it off.
    test "a master with no site of their own reads the master site's switch", %{user: user} do
      # THE ROUTING CACHE, NOT THE TABLE. `site_id/1` asks `SiteState` because every request already
      # has — it is an ETS read, and the sidebar is rebuilt on every admin mount. A row written
      # straight to the database is not in it, so a test that only creates one proves nothing about
      # what the sidebar will see.
      name = "mastersite#{System.unique_integer([:positive])}"
      master_site = create_site!(name: name, host: "#{name}.test")

      # `create_site!` has already put it in the cache as an ordinary site, and `save/1` refuses a
      # host that is there. Marking it master is a replacement, not an addition.
      SiteState.delete(master_site.id)

      :ok =
        SiteState.save(%{
          id: master_site.id,
          name: master_site.name,
          host: master_site.host,
          priority: 0,
          active: true,
          master: true
        })

      on_exit(fn -> SiteState.delete(master_site.id) end)

      item =
        Item.new!(%{
          key: "shop",
          label: "Shop",
          path: "/admin/dashboard/shop",
          extension: :mishka_shop
        })

      assert Sidebar.visible_to?(item, %{user | site_id: nil})

      # WHICHEVER MASTER THE CACHE ANSWERS WITH, and not the one this test happens to have made.
      # `SiteState.get_by_master/0` is `Enum.find` over a table the whole suite shares — 46 other
      # files write sites into it — so in a full run the first master in ETS order need not be this
      # one, and the switch went on a site the sidebar was never going to read. What is under test
      # is that a master reads the master SITE's switch, which is as true of the site the sidebar
      # actually resolves; asserting against that is the same assertion without the ordering.
      {:ok, %{id: reads_from}} = SiteState.get_by_master()

      SettingsState.put(reads_from, "mishka_shop.active", false)
      on_exit(fn -> SettingsState.delete(reads_from, "mishka_shop.active") end)

      refute Sidebar.visible_to?(item, %{user | site_id: nil}),
             "the master site's own switch did not reach the master"
    end

    # CORE CANNOT BE SWITCHED OFF. An entry naming no extension has no switch to read, and an admin
    # left without Home and Settings could not turn anything back on.
    test "an entry that names no extension is never switched off", %{user: user} do
      core = Item.new!(%{key: "home", label: "Home", path: "/admin/dashboard"})

      override("mishka_shop.active", false)

      assert Sidebar.visible_to?(core, user, nil)
    end

    test "hiding a group hides the whole section, items included", %{user: user} do
      override(Sidebar.visible_key("account"), false)

      refute group(Sidebar.menu(user), "account")
    end

    test "hiding the last item of a group drops the group with it", %{user: user} do
      for key <- ["account.users", "account.permissions"],
          do: override(Sidebar.visible_key(key), false)

      refute group(Sidebar.menu(user), "account")
    end

    test "a garbage order is ignored in favour of the declaration", %{user: user} do
      override(Sidebar.order_key("account"), "first")

      assert labels(Sidebar.menu(user).main) == ["Home", "Runtime", "Account"]
    end

    test "a garbage visibility does not hide the entry", %{user: user} do
      override(Sidebar.visible_key("account"), "no")

      assert group(Sidebar.menu(user), "account")
    end

    test "an override on one site leaves every other admin's nav alone", %{user: master} do
      site = create_site!()
      tenant = create_user_with_permissions!(["*"], site_id: site.id)
      key = Sidebar.visible_key("runtime.medias")

      SettingsState.put(site.id, key, false)
      on_exit(fn -> SettingsState.delete(site.id, key) end)

      refute "Media" in labels(group(Sidebar.menu(tenant), "runtime").items)
      assert "Media" in labels(group(Sidebar.menu(master), "runtime").items)
    end
  end

  describe "nav: false — pages that are not links" do
    test "a page declared with nav: false never renders in the sidebar" do
      user = create_user_with_permissions!(["*"])
      shown = Sidebar.menu(user).main ++ Sidebar.menu(user).footer

      paths =
        Enum.flat_map(shown, fn entry ->
          Enum.map(Map.get(entry, :items, [entry]), & &1.path)
        end)

      refute "/admin/dashboard/notifications" in paths
      refute "/admin/dashboard/runtime/activity" in paths
    end

    test "but it still declares a gate, which is the whole point" do
      assert Sidebar.permissions("runtime.activity") == ["admin:dashboard:runtime:activity"]
      assert Sidebar.permissions("notifications") == [{:under, "admin:dashboard"}]
    end

    test "and it gets no order/visible settings, since there is nothing to arrange" do
      keys = Enum.map(Sidebar.settings_definitions(), & &1.key)

      refute Sidebar.order_key("notifications") in keys
      refute Sidebar.visible_key("notifications") in keys
    end
  end

  describe "permissions/2 — the one place a page's gate is written" do
    test "returns what the matching item declares" do
      assert Sidebar.permissions("account.users") == ["admin:dashboard:user"]
    end

    test "raises on an unknown key rather than returning an ungated empty list" do
      assert_raise ArgumentError, ~r/no sidebar item declares the key/, fn ->
        Sidebar.permissions("account.userz")
      end
    end

    # Asserted by MODULE, which is what `PageGuard` actually asks. Matching on path used to be an
    # adequate proxy only because every core route was static; a parameterized one
    # (`/runtime/builder/:section/:id`) can never equal a declaration's path, and two routes may
    # legitimately share one LiveView. The module is what the router already resolved, and it is the
    # key the gate is looked up by.
    test "every routed core page has a declaration" do
      declared = MapSet.new(Sidebar.core_menu().items, & &1.module)

      for {:live, path, module, _action} <- MishkaCmsCoreWeb.Routes.routes(:admin) do
        assert MapSet.member?(declared, module),
               "#{inspect(module)} (#{path}) has no sidebar declaration, so no gate"
      end
    end

    test "every declared nav link points at a real static path" do
      for item <- Sidebar.core_menu().items, item.nav do
        assert String.starts_with?(item.path, "/admin/dashboard") or item.path == "/"

        refute String.contains?(item.path, ":"),
               "#{item.path} is a link, so it cannot take params"
      end
    end
  end

  describe "permissions_for_module/1 — what PageGuard asks" do
    test "answers with the declaration for the mounted module" do
      assert Sidebar.permissions_for_module(
               MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.User.Index
             ) == ["admin:dashboard:user"]
    end

    test "an undeclared module gets [], which PageGuard reads as REFUSE" do
      assert Sidebar.permissions_for_module(SomeModule.Nobody.Declared) == []
      assert Sidebar.permissions_for_module(nil) == []
    end

    test "a page with no link of its own is still answered" do
      assert Sidebar.permissions_for_module(MishkaCmsCoreWeb.Live.Admin.Dashboard.Activity.Index) ==
               ["admin:dashboard:runtime:activity"]
    end

    test "EVERY routed admin page is declared — an omission would lock the page" do
      declared = MapSet.new(Sidebar.core_menu().items, & &1.module)

      for {:live, path, module, _action} <- MishkaCmsCoreWeb.Routes.routes(:admin) do
        assert MapSet.member?(declared, module),
               "#{path} (#{inspect(module)}) has no sidebar declaration, so PageGuard would refuse it"
      end
    end

    test "no two entries claim the same module with different permissions" do
      Sidebar.core_menu().items
      |> Enum.group_by(& &1.module, & &1.permissions)
      |> Enum.each(fn {module, lists} ->
        assert Enum.uniq(lists) |> length() == 1,
               "#{inspect(module)} is declared twice with different gates: #{inspect(lists)}"
      end)
    end

    test "the dashboard itself is reachable, so PageGuard's redirect can never loop" do
      user = create_user_with_permissions!(["admin:dashboard:blog:post"])
      required = Sidebar.permissions_for_module(MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index)

      assert MishkaCmsCore.Accounts.Checks.AccessPermissions.match?(user, %{},
               permissions: required
             )
    end
  end

  describe "credit/1 — whose name and page the line under it carries" do
    test "names no extension for a core page, an undeclared one, or none at all" do
      assert Sidebar.credit(MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index) == nil
      assert Sidebar.credit(SomeModule.Nobody.Declared) == nil
      assert Sidebar.credit(nil) == nil
    end
  end

  describe "labels — marked where declared, translated where drawn" do
    test "the core declares its labels in English, the text the sidebar translates" do
      %{groups: groups, items: items} = Sidebar.core_menu()

      assert "Runtime" in labels(groups)
      assert "Sites" in labels(items)
    end

    test "a setting's label names its entry through a template the settings page translates" do
      definitions = Map.new(Sidebar.settings_definitions(), &{&1.key, &1})

      assert definitions[Sidebar.order_key("runtime.sites")].label ==
               {"%{label} — position", label: "Sites"}

      assert Settings.text(definitions[Sidebar.order_key("runtime.sites")].label) ==
               "Sites — position"

      Gettext.put_locale("fa")
      on_exit(fn -> Gettext.put_locale("en") end)

      assert Settings.text(definitions[Sidebar.order_key("runtime.sites")].label) ==
               "[fa] [fa] Sites — position"
    end
  end

  describe "the area each page asks for" do
    defp opens?(user, module) do
      AccessPermissions.match?(user, %{}, permissions: Sidebar.permissions_for_module(module))
    end

    test "the builder and its canvas open to any name that opens a builder, and to no other" do
      for name <- [
            "admin:dashboard:runtime:page",
            "admin:dashboard:runtime:layout",
            "admin:dashboard:runtime:component",
            "admin:dashboard:runtime:error_page",
            "admin:dashboard:code"
          ],
          module <- [BuilderLive, CanvasLive] do
        assert opens?(create_user_with_permissions!([name]), module),
               "#{inspect(module)} refused #{name}"
      end

      for name <- ["admin:dashboard:runtime:stylesheet", "admin:api:runtime:page"],
          module <- [BuilderLive, CanvasLive] do
        refute opens?(create_user_with_permissions!([name]), module),
               "#{inspect(module)} opened to #{name}"
      end
    end

    test "a content list opens to every dashboard admin and to no API admin" do
      unrelated = create_user_with_permissions!(["admin:dashboard:blog:comment"])
      api = create_user_with_permissions!(["admin:api:*"])

      for module <- [Runtime.Page.Index, Runtime.Media.Index, Runtime.Translation.Index] do
        assert opens?(unrelated, module), "#{inspect(module)} refused a dashboard admin"
        refute opens?(api, module), "#{inspect(module)} opened to an API admin"
      end
    end

    test "Sites, Users, Permissions and Activity open to their own area and not another's" do
      pages = create_user_with_permissions!(["admin:dashboard:runtime:page"])

      for {area, module} <- [
            {"admin:dashboard:runtime:site", Runtime.Site.Index},
            {"admin:dashboard:user", Account.User.Index},
            {"admin:dashboard:permission", Account.Permission.Index},
            {"admin:dashboard:runtime:activity",
             MishkaCmsCoreWeb.Live.Admin.Dashboard.Activity.Index}
          ] do
        holder = create_user_with_permissions!([area])

        assert opens?(holder, module), "#{inspect(module)} refused its own area"
        refute opens?(pages, module), "#{inspect(module)} opened to the page area"
      end
    end

    test "Home, Notifications and Settings open to any dashboard admin and to no API admin" do
      narrow = create_user_with_permissions!(["admin:dashboard:document:section"])
      api = create_user_with_permissions!(["admin:api:runtime:page"])

      for module <- [
            MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index,
            MishkaCmsCoreWeb.Live.Admin.Dashboard.Notification.Index,
            Runtime.SettingsLive
          ] do
        assert opens?(narrow, module), "#{inspect(module)} refused a dashboard admin"
        refute opens?(api, module), "#{inspect(module)} opened to an API admin"
      end
    end

    # THE SECTION EXTENSIONS HANG THEIR ENTRY POINTS IN: an admin of one extension area reaches its
    # link through it, so the section itself opens to anyone under `admin:dashboard`.
    test "the Plugins section opens to any dashboard admin and to no API admin" do
      plugins = Enum.find(Sidebar.core_menu().groups, &(&1.key == "plugins"))

      for names <- [
            ["admin:dashboard:blog:post"],
            ["admin:dashboard:document:section"],
            ["admin:dashboard:runtime:page"]
          ] do
        assert Sidebar.visible_to?(plugins, create_user_with_permissions!(names)),
               "Plugins was hidden from #{inspect(names)}"
      end

      for names <- [["admin:api:*"], ["admin:api:blog:post"]] do
        refute Sidebar.visible_to?(plugins, create_user_with_permissions!(names)),
               "Plugins was shown to #{inspect(names)}"
      end
    end

    test "a refused dashboard admin lands on Home, and anyone else on the site root" do
      assert Sidebar.landing_path(create_user_with_permissions!(["admin:dashboard:blog:post"])) ==
               "/admin/dashboard"

      assert Sidebar.landing_path(create_user_with_permissions!(["admin:api:*"])) == "/"
      assert Sidebar.landing_path(create_user!()) == "/"
      assert Sidebar.landing_path(nil) == "/"
    end
  end

  describe "settings_definitions/0" do
    test "registers an order and a visibility switch for every entry the nav renders" do
      keys = Enum.map(Sidebar.settings_definitions(), & &1.key)
      %{groups: groups, items: items} = Sidebar.collect()

      # `nav: false` items are pages, not links — there is no position to set and nothing to hide.
      for entry <- groups ++ Enum.filter(items, & &1.nav) do
        assert Sidebar.order_key(entry.key) in keys
        assert Sidebar.visible_key(entry.key) in keys
      end
    end

    test "every definition lands in the Sidebar tab and is site-overridable" do
      for definition <- Sidebar.settings_definitions() do
        assert definition.category == "sidebar"
        assert definition.scope == :both
        assert definition.source == :plugin
      end
    end

    test "a definition inherits its entry's permissions, so it is hidden with the menu" do
      definitions = Map.new(Sidebar.settings_definitions(), &{&1.key, &1})

      assert definitions[Sidebar.order_key("account.users")].permission == [
               "admin:dashboard:user"
             ]
    end

    test "an entry every dashboard admin sees is arranged by the settings area alone" do
      definitions = Map.new(Sidebar.settings_definitions(), &{&1.key, &1})

      assert definitions[Sidebar.order_key("home")].permission == ["admin:dashboard:setting"]
      assert definitions[Sidebar.visible_key("runtime")].permission == ["admin:dashboard:setting"]

      assert definitions[Sidebar.visible_key("runtime.pages")].permission == [
               "admin:dashboard:setting"
             ]
    end

    # A CONTENT LIST IS SEEN BY EVERY DASHBOARD ADMIN, so hiding or moving it changes the menu of all
    # of them: the settings area arranges it, and an admin of the list's own area does not.
    test "each content list is arranged by the settings area, and not by its own area" do
      definitions = Map.new(Sidebar.settings_definitions(), &{&1.key, &1})

      lists = [
        {"runtime.components", "component"},
        {"runtime.layouts", "layout"},
        {"runtime.error_pages", "error_page"},
        {"runtime.pages", "page"},
        {"runtime.medias", "media"},
        {"runtime.stylesheets", "stylesheet"},
        {"runtime.js_hooks", "js_hook"},
        {"runtime.translations", "translation"},
        {"runtime.redirects", "redirect"}
      ]

      areas = Enum.map(lists, &elem(&1, 1))
      holders = Map.new(areas, &{&1, create_user_with_permissions!(["admin:dashboard:#{&1}"])})
      settings = create_user_with_permissions!(["admin:dashboard:setting"])

      for {{key, area}, index} <- Enum.with_index(lists),
          other = Enum.at(areas, rem(index + 1, length(areas))),
          setting <- [Sidebar.order_key(key), Sidebar.visible_key(key)] do
        definition = Map.fetch!(definitions, setting)

        refute Settings.permitted?(definition, holders[area]), "#{setting} let #{area} in"
        assert Settings.permitted?(definition, settings), "#{setting} refused the settings area"
        refute Settings.permitted?(definition, holders[other]), "#{setting} let #{other} in"
      end
    end

    test "items are grouped under their section's heading" do
      definitions = Map.new(Sidebar.settings_definitions(), &{&1.key, &1})

      assert definitions[Sidebar.visible_key("runtime.sites")].group == "Runtime"
      assert definitions[Sidebar.visible_key("home")].group == "Top level"
      assert definitions[Sidebar.visible_key("runtime")].group == "Sections"
    end
  end

  describe "descriptors" do
    test "an item refuses to build without the fields the sidebar renders from" do
      assert_raise ArgumentError, fn -> Item.new!(%{key: "x", label: "X"}) end
      assert_raise ArgumentError, fn -> Group.new!(%{key: "x"}) end
    end

    test "an item defaults to the main nav, no group, and no extra gate" do
      item = Item.new!(%{key: "x", label: "X", path: "/admin/dashboard/x"})

      assert item.position == :main
      assert item.group == nil
      assert item.permissions == []
    end
  end
end
