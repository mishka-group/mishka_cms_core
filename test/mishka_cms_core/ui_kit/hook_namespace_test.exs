defmodule MishkaCmsCore.UiKit.HookNamespaceTest do
  @moduledoc """
  Everything a kit installs is named after the kit — including its JavaScript hooks.

  ## What was inconsistent

  Chelekom shipped 136 components as `chelekom-*` and its theme as `chelekom-theme`, and its eight
  hooks as bare `carousel`, `floating`, `sidebar`. Three costs, and only the first is cosmetic:

    * the admin's hook list put a kit's rows among the site's own with nothing saying where they
      came from — which is what was reported
    * `UiKitHandler.uninstall_kit!/2` purges components by the `<kit>-` prefix and hooks by exact
      name, so the two rules disagreed about what belongs to a kit
    * the name IS the key, so a second kit shipping its own `carousel` would silently overwrite
      this one

  ## And a rename has to migrate

  An install over an older bundle must REMOVE the row it is renaming rather than leave both. The
  bundle names what it replaces, in `extra.replaces`, so the purge is bounded by what the kit itself
  claims — never by stripping a prefix and deleting whatever matches, which would take a site's own
  `carousel` with it on a first install.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler, as: Installer
  alias MishkaCmsCore.Runtime.JsHook

  require Ash.Query

  @moduletag :integration

  @bundle MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

  defp bundle, do: @bundle |> File.read!() |> Jason.decode!()

  defp hook_rows do
    JsHook
    |> Ash.Query.filter(is_nil(site_id))
    |> Ash.read!(authorize?: false)
  end

  describe "the shipped bundle" do
    test "every hook it installs is named after the kit, like every component and the theme" do
      %{"name" => kit, "js_hooks" => hooks, "components" => components} = bundle()

      for hook <- hooks do
        assert String.starts_with?(hook["name"], kit <> "-"),
               "#{hook["name"]} is not namespaced by #{kit}"
      end

      for component <- components do
        assert String.starts_with?(component["name"], kit <> "-")
      end
    end

    test "each hook says which bare name it replaces, so an upgrade can remove it" do
      for hook <- bundle()["js_hooks"] do
        replaced = get_in(hook, ["extra", "replaces"])

        assert is_binary(replaced) and replaced != ""
        assert hook["name"] == bundle()["name"] <> "-" <> replaced
      end
    end

    # THE REWRITE HAS TO AGREE WITH THE RUNTIME, not merely be consistent with itself. The live key
    # is rebuilt from the ROW NAME by `format_hook_name/2`, so a template naming anything else finds
    # no hook at all — and a hook that does not mount is a component that silently does nothing.
    test "every phx-hook a component writes is the key the runtime will build from its row" do
      %{"js_hooks" => hooks, "components" => components} = bundle()

      keys =
        MapSet.new(hooks, fn hook ->
          JavaScriptCompiler.browser_name(%{name: hook["name"], is_global: true}, nil)
        end)

      written =
        components
        |> Enum.flat_map(fn component ->
          component
          |> Jason.encode!()
          |> then(&Regex.scan(~r/phx-hook=\\"([A-Za-z]+)\\"/, &1))
          |> Enum.map(fn [_whole, name] -> name end)
        end)
        |> Enum.uniq()

      refute written == [], "the fixture has to reference at least one hook"

      for name <- written do
        assert MapSet.member?(keys, name),
               "#{name} is written in a template but no installed row builds that key"
      end
    end
  end

  describe "installing over an older bundle" do
    setup do
      on_exit(fn -> Installer.uninstall_kit!(@bundle) end)
      :ok
    end

    test "the bare rows the kit used to ship are gone, and the namespaced ones are there" do
      # The state an older Chelekom left behind: one hook per bare name.
      for hook <- bundle()["js_hooks"] do
        JsHook
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: get_in(hook, ["extra", "replaces"]),
            content: "export default {};",
            format: :js,
            active: true
          },
          authorize?: false
        )
        |> Ash.create!()
      end

      before = hook_rows() |> Enum.map(& &1.name)
      assert "floating" in before

      {:ok, _installed} = Installer.install_kit!(@bundle)

      after_names = hook_rows() |> Enum.map(& &1.name)

      for hook <- bundle()["js_hooks"] do
        assert hook["name"] in after_names
        refute get_in(hook, ["extra", "replaces"]) in after_names
      end
    end

    # AND IT SAYS SO. A rename is the one thing an install does that a stored template cannot follow:
    # a page that hand-wrote `phx-hook="GlobalFloating"` keeps saying so, and the row it named is
    # gone. The installer cannot rewrite somebody's pages, so it names the new key in the log — the
    # only thing an operator can act on.
    @tag :capture_log
    test "the log names the old key and the new one, for the templates that hand-wrote it" do
      JsHook
      |> Ash.Changeset.for_create(
        :master_create,
        %{name: "clipboard", content: "export default {};", format: :js, active: true},
        authorize?: false
      )
      |> Ash.create!()

      logged =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _installed} = Installer.install_kit!(@bundle)
        end)

      assert logged =~ "renamed the js_hook clipboard"
      assert logged =~ "GlobalClipboard"
      assert logged =~ "GlobalChelekomClipboard"
    end

    # THE PURGE IS BOUNDED BY WHAT THE BUNDLE CLAIMS. "Delete every hook whose name is what this one
    # would be called without its kit" would take a site's own `carousel` on a FIRST install.
    test "a hook the kit does not claim is left alone" do
      site = create_site!(name: "hooks-host", host: "hooks.test", active: true)

      JsHook
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "carousel",
          site_id: site.id,
          content: "export default {mounted(){}};",
          format: :js,
          active: true
        },
        authorize?: false
      )
      |> Ash.create!()

      {:ok, _installed} = Installer.install_kit!(@bundle)

      mine =
        JsHook
        |> Ash.Query.filter(site_id == ^site.id and name == "carousel")
        |> Ash.read!(authorize?: false)

      assert length(mine) == 1,
             "a site's own hook must survive a kit install that renames its own"
    end
  end
end
