# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.AuthoringExampleTest do
  @moduledoc """
  The bundle in `priv/cms_ui_kits/authoring/` is the answer to "how do I import my own component",
  and it is executable rather than illustrative.

  ## Why the example is a test

  A third-party developer's first contact with this CMS is a JSON file they have to get right with no
  feedback loop: a bundle that installs is not yet a bundle that renders, and the ways it silently
  half-works — an undeclared assign, a `phx-hook` naming a key nothing builds, an opener the editor
  cannot see — all surface much later, on somebody's canvas, as a red box.

  So every claim the README makes is asserted here against the file it points at. A guide that has
  drifted from the thing it documents is worse than no guide, and prose cannot drift if the prose is
  checked.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.JsHook
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.UiKit.Contract

  require Ash.Query

  @moduletag :integration

  @dir Path.join([:code.priv_dir(:mishka_cms_core), "cms_ui_kits", "authoring"])
  @bundle Path.join(@dir, "acme.json")
  @readme Path.join(@dir, "README.md")

  defp bundle, do: @bundle |> File.read!() |> Jason.decode!()

  describe "the guide and the file it points at" do
    test "both exist, and the guide names the file" do
      assert File.exists?(@bundle)
      assert File.read!(@readme) =~ "acme.json"
    end

    test "every component passes the contract the installer checks" do
      for component <- bundle()["components"] do
        assert Contract.check(component) == :ok,
               "#{component["name"]} would be skipped by the installer"
      end
    end

    # RULE 1 of the checklist. `uninstall_kit!/2` deletes components by this prefix, so a component
    # named anything else installs and can never be removed by name.
    test "the kit name prefixes every component, hook and stylesheet" do
      %{"name" => kit} = data = bundle()

      for row <- data["components"] ++ data["js_hooks"] ++ data["stylesheets"] do
        assert String.starts_with?(row["name"], kit <> "-"),
               "#{row["name"]} is not namespaced by #{kit}"
      end
    end

    # RULE 2. A template that does not parse cannot be edited, only red-boxed.
    test "every template parses as HEEx on its own" do
      for component <- bundle()["components"] do
        assert {:ok, _tree} = Tree.parse(component["template"]),
               "#{component["name"]}'s template does not parse"
      end
    end

    # RULE 3. An undeclared `@thing` raises inside LiveView's diff, which the editor can only show as
    # a red box on somebody's canvas — long after the bundle was written.
    test "every assign a template reads is declared as an attribute or a slot" do
      for component <- bundle()["components"] do
        declared =
          MapSet.new(
            Enum.map(component["attrs"], & &1["name"]) ++
              Enum.map(component["slots"], & &1["name"])
          )

        read =
          ~r/@([a-z_][a-zA-Z0-9_]*)/
          |> Regex.scan(component["template"])
          |> Enum.map(fn [_whole, name] -> name end)
          |> Enum.uniq()

        for name <- read do
          assert MapSet.member?(declared, name),
                 "#{component["name"]} reads @#{name} and declares no such attribute"
        end
      end
    end

    # RULE 4. The picker locks a dependency so it cannot be unchecked; naming one that does not exist
    # locks nothing and the component renders half of itself.
    test "every dependency names a component the bundle actually ships" do
      names = MapSet.new(bundle()["components"], & &1["name"])

      for component <- bundle()["components"], dependency <- component["dependencies"] do
        assert MapSet.member?(names, dependency),
               "#{component["name"]} depends on #{dependency}, which is not in this bundle"
      end
    end

    # RULE 5. An example is how a component is discovered — the palette renders them as the preview.
    test "every component ships at least two examples, each rendering itself" do
      for component <- bundle()["components"] do
        assert length(component["examples"]) >= 2, "#{component["name"]} ships too few examples"

        for example <- component["examples"] do
          assert String.contains?(example, component["name"])
          assert {:ok, _tree} = Tree.parse(example)
        end
      end
    end

    # RULE 7. The live key is rebuilt from the ROW NAME, so a template naming anything else finds no
    # hook — and a hook that does not mount is a component that silently does nothing.
    test "every phx-hook a template writes is the key its own row will build" do
      data = bundle()

      keys =
        MapSet.new(data["js_hooks"], fn hook ->
          JavaScriptCompiler.browser_name(%{name: hook["name"], is_global: true}, nil)
        end)

      written =
        for component <- data["components"],
            [_whole, name] <- Regex.scan(~r/phx-hook="([A-Za-z]+)"/, component["template"]),
            do: name

      refute written == [], "the example has to demonstrate a hook"

      for name <- written do
        assert MapSet.member?(keys, name),
               "#{name} is written in a template but no row in this bundle builds that key"
      end
    end
  end

  describe "installing it" do
    setup do
      on_exit(fn -> UiKitHandler.uninstall_kit!(@bundle) end)
      :ok
    end

    test "every row in the file becomes a row in the database" do
      {:ok, result} = UiKitHandler.install_kit!(@bundle)

      assert length(result.components) == 2
      assert length(result.js_hooks) == 1
      assert length(result.stylesheets) == 1

      names = Enum.map(result.components, & &1.name) |> Enum.sort()
      assert names == ["acme-badge", "acme-panel"]
    end

    test "the hook lands under the namespaced name the templates were written against" do
      {:ok, _result} = UiKitHandler.install_kit!(@bundle)

      rows =
        JsHook
        |> Ash.Query.filter(name == "acme-reveal")
        |> Ash.Query.load(:is_global)
        |> Ash.read!(authorize?: false)

      assert length(rows) == 1
      assert hd(rows).is_global, "a bundle row ships site_id: null, which is what makes it global"
      assert JavaScriptCompiler.browser_name(hd(rows), nil) == "GlobalAcmeReveal"
    end

    test "uninstalling by the kit name takes every row with it" do
      {:ok, _result} = UiKitHandler.install_kit!(@bundle)
      :ok = UiKitHandler.uninstall_kit!(@bundle)

      left =
        JsHook
        |> Ash.Query.filter(name == "acme-reveal")
        |> Ash.read!(authorize?: false)

      assert left == []
    end
  end

  # THE EDITOR'S SIDE OF THE CONTRACT. A kit author needs to know that what they declared is what the
  # builder will offer, and this is the only place that is checked without a browser.
  describe "what the editor makes of it" do
    test "the panel's declared options become a select, and its required id is marked" do
      panel = Enum.find(bundle()["components"], &(&1["name"] == "acme-panel"))

      tone = Enum.find(panel["attrs"], &(&1["name"] == "tone"))
      assert tone["opts"]["values"] == ["quiet", "loud"]
      assert tone["opts"]["default"] == "quiet"

      id = Enum.find(panel["attrs"], &(&1["name"] == "id"))
      assert id["opts"]["required"] == true
    end

    test "the opener commands sit on the root element, not on something inside it" do
      panel = Enum.find(bundle()["components"], &(&1["name"] == "acme-panel"))
      {:ok, tree} = Tree.parse(panel["template"])

      root = tree |> Tree.children(:root) |> List.first()

      assert Node.attr(root, "data-pb-open")
      assert Node.attr(root, "data-pb-close")
    end
  end
end
