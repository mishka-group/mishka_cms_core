# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.HooksTest do
  @moduledoc """
  Which JS hooks the editor offers, and the one it must not.

  A site's hook is compiled under a browser name built from the site's own name. A GLOBAL document —
  a component used on every site — has no site to take one from, so offering a site's hook there
  asked the compiler to prefix a name with nothing. That raised on the way into the editor and took
  the whole component section down with a 500, before anything rendered.

  Leaving them out is also the honest answer rather than only the safe one: a component used on
  every site cannot rely on a hook that exists on one of them.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Hooks
  alias MishkaCmsCore.Test.Plugins.BuilderJsHookPlugin
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :unit

  setup do
    site = create_site!()
    master = create_user_with_permissions!(["*"])

    %{site: site, master: master, tenant: create_user_with_permissions!(["*"], site_id: site.id)}
  end

  describe "what a document with a site is offered" do
    test "its own site's hooks, and the global ones", context do
      _own = create_js_hook!(site_id: context.site.id, name: "own-hook", active: true)
      _global = create_js_hook!(name: "shared-hook", active: true)

      offered = Hooks.available(context.master, context.site.id, context.site.name)
      names = Enum.map(offered, & &1.hook)

      assert "own-hook" in names
      assert "shared-hook" in names
    end

    # A SITE ADMIN IS PROMISED THE GLOBALS AND WAS HANDED NONE. The globals were fetched with the
    # tenant still set, and Ash adds `site_id == ^tenant` to a read that carries one — so the fetch
    # asked for rows that are site-less AND belong to the site, which is nothing at all.
    test "a site admin is offered the global hooks too, not only their own", context do
      _own = create_js_hook!(site_id: context.site.id, name: "own-hook", active: true)
      _global = create_js_hook!(name: "shared-hook", active: true)

      names =
        context.tenant
        |> Hooks.available(context.site.id, context.site.name)
        |> Enum.map(& &1.hook)

      assert "own-hook" in names
      assert "shared-hook" in names
    end

    # MORE HOOKS THAN A PAGE HOLDS, on purpose. A master's read was `:master_read`, which is
    # `default_limit: 20`, and the site was picked out of the twenty rows that came back rather than
    # asked for in the query — so a site with more hooks than that was simply short some of them,
    # with no error and nothing to notice. Which ones went missing was whatever order the database
    # chose, so the count is what this asserts.
    test "a master is offered every hook the site has, not the first page of them", context do
      for index <- 1..25 do
        create_js_hook!(site_id: context.site.id, name: "own-hook-#{index}", active: true)
      end

      _global = create_js_hook!(name: "shared-hook", active: true)

      names =
        context.master
        |> Hooks.available(context.site.id, context.site.name)
        |> Enum.map(& &1.hook)

      for index <- 1..25 do
        assert "own-hook-#{index}" in names, "the site's own hook #{index} was left out"
      end

      assert "shared-hook" in names
    end

    # AND NOT ANOTHER SITE'S. The cap is gone, so every row in the database is now a candidate and
    # the scoping is the only thing keeping a neighbour's hook out of this site's picker.
    test "and never another site's, however many there are", context do
      elsewhere =
        create_site!(name: "hooks-elsewhere", host: "hooks-elsewhere.test", active: true)

      for index <- 1..25 do
        create_js_hook!(site_id: elsewhere.id, name: "elsewhere-hook-#{index}", active: true)
      end

      _own = create_js_hook!(site_id: context.site.id, name: "own-hook", active: true)

      names =
        context.master
        |> Hooks.available(context.site.id, context.site.name)
        |> Enum.map(& &1.hook)

      assert "own-hook" in names
      assert Enum.all?(names, &(not String.starts_with?(&1, "elsewhere-hook")))
    end
  end

  describe "what a document with no site is offered" do
    # THE ONE THAT 500'd. A global component, opened while a site's hook existed.
    test "only the global hooks, and it does not raise", context do
      _own = create_js_hook!(site_id: context.site.id, name: "site-only-hook", active: true)
      _global = create_js_hook!(name: "shared-hook", active: true)

      offered = Hooks.available(context.master, context.site.id, nil)
      names = Enum.map(offered, & &1.hook)

      refute "site-only-hook" in names
      assert "shared-hook" in names
    end

    test "and every one it offers has a usable name", context do
      _global = create_js_hook!(name: "shared-hook", active: true)

      for entry <- Hooks.available(context.master, context.site.id, nil) do
        assert is_binary(entry.name) and entry.name != ""
      end
    end
  end

  # WHAT THE PICKER DRAWS IS WHAT APPLY IS ALLOWED TO WRITE. The picker read the appended list and
  # `known?/4` read `available/3`, so a hook an extension contributed was offered in the select, and
  # then refused by the write behind it — every time, for every contribution.
  describe "a hook an extension contributes" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: BuilderJsHookPlugin,
          event: "builder:js_hooks",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("builder:js_hooks", :start, false)
      on_exit(fn -> Event.unregister(:name, BuilderJsHookPlugin, false) end)

      %{contributed: BuilderJsHookPlugin.hook()}
    end

    test "is offered beside the site's own", context do
      _own = create_js_hook!(site_id: context.site.id, name: "own-hook", active: true)

      offered = Hooks.registry(context.master, context.site.id, context.site.name)

      assert context.contributed.name in Enum.map(offered, & &1.name)
      assert "own-hook" in Enum.map(offered, & &1.hook)
    end

    test "and known?/4 recognises it, so Apply writes it", context do
      assert Hooks.known?(
               context.master,
               context.site.id,
               context.site.name,
               context.contributed.name
             )
    end

    test "while a name nobody offers is still not known", context do
      refute Hooks.known?(context.master, context.site.id, context.site.name, "NotARealHook")
    end
  end

  describe "the browser name a hook is compiled under" do
    test "a global hook is prefixed Global, whatever the site" do
      hook = %{name: "my-thing", is_global: true}

      assert JavaScriptCompiler.browser_name(hook, "some-site") == "GlobalMyThing"
      assert JavaScriptCompiler.browser_name(hook, nil) == "GlobalMyThing"
    end

    test "a site's hook is prefixed with the site" do
      hook = %{name: "my-thing", is_global: false}

      assert JavaScriptCompiler.browser_name(hook, "shop_front") == "ShopFrontMyThing"
      assert JavaScriptCompiler.browser_name(hook, "shop-front") == "ShopFrontMyThing"
    end

    # Callers should not ask — but answering the bare name beats raising, which is what it did.
    test "and asking for one without a site answers rather than raising" do
      hook = %{name: "my-thing", is_global: false}

      assert JavaScriptCompiler.browser_name(hook, nil) == "MyThing"
    end
  end
end
