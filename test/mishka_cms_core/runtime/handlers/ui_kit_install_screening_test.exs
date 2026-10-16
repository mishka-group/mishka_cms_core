# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Handlers.UiKitInstallScreeningTest do
  @moduledoc """
  One malformed row in a bundle costs that row, and nothing else.

  `Contract.partition/1` screened `components`, so a bad one was skipped and named in the log.
  `js_hooks` and `stylesheets` went straight to the resource — a stylesheet whose `kind` was a word
  this CMS does not have reached `String.to_existing_atom/1`, raised out of `Ash.transaction`, out of
  `install_kit!/2` and out of the caller's `handle_event`. **Zero of 136 perfectly good components
  installed**, and nothing on screen named the row that did it.

  The asymmetry was the bug. It matters more now that a bundle can arrive from a URL an operator
  pasted, where "not quite right" is the normal case rather than the exceptional one.

  `async: false` — installs write global runtime rows.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.JsHook
  alias MishkaCmsCore.Runtime.Stylesheet

  setup do
    dir = Path.join(System.tmp_dir!(), "kit_screen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp write!(dir, name, bundle) do
    path = Path.join(dir, "#{name}.json")
    File.write!(path, Jason.encode!(Map.merge(%{"$schema" => "mishka.ui_kit.bundle.v3"}, bundle)))
    path
  end

  defp rows(resource, name) do
    resource
    |> Ash.Query.filter(name == ^name)
    |> Ash.read!(authorize?: false, action: :read_any, page: [limit: 5])
    |> Map.fetch!(:results)
  end

  describe "a stylesheet the resource cannot accept" do
    test "does not take the components down with it", %{dir: dir} do
      path =
        write!(dir, "screen_sheet", %{
          "name" => "screen_sheet",
          "components" => [
            %{"name" => "screen-sheet-card", "type" => "general", "template" => "<div>c</div>"}
          ],
          "stylesheets" => [
            %{"name" => "screen-sheet-theme", "content" => "@theme {}", "kind" => "tokens"}
          ]
        })

      UiKitHandler.install_kit!(path, site_id: nil)

      assert rows(Component, "screen-sheet-card") != [],
             "a bad stylesheet used to cost every component in the bundle"

      # The row is not dropped — `kind` is coerced to what the attribute actually allows, which is
      # its own default, rather than raising on a word nobody has ever used.
      assert [sheet] = rows(Stylesheet, "screen-sheet-theme")
      assert sheet.kind in [:app_base, :theme, :base, :custom]

      UiKitHandler.uninstall_kit!(path, kit_name: "screen_sheet")
    end
  end

  describe "a hook with no body" do
    test "is skipped, and everything else installs", %{dir: dir} do
      path =
        write!(dir, "screen_hook", %{
          "name" => "screen_hook",
          "components" => [
            %{"name" => "screen-hook-card", "type" => "general", "template" => "<div>c</div>"}
          ],
          "js_hooks" => [
            %{"name" => "ScreenHookEmpty"},
            %{"name" => "ScreenHookGood", "content" => "export default {}"}
          ]
        })

      UiKitHandler.install_kit!(path, site_id: nil)

      assert rows(Component, "screen-hook-card") != []
      # Stored slugified — `JsHook` downcases the PascalCase module name it arrives as.
      assert rows(JsHook, "screenhookgood") != [], "the good hook still installs"

      assert rows(JsHook, "screenhookempty") == [],
             "the body-less one is skipped, not written blank"

      UiKitHandler.uninstall_kit!(path, kit_name: "screen_hook")
    end
  end

  describe "a row that is not an object at all" do
    test "is skipped rather than raising", %{dir: dir} do
      path =
        write!(dir, "screen_junk", %{
          "name" => "screen_junk",
          "components" => [
            %{"name" => "screen-junk-card", "type" => "general", "template" => "<div>c</div>"}
          ],
          "stylesheets" => ["this is a string, not a stylesheet"]
        })

      UiKitHandler.install_kit!(path, site_id: nil)

      assert rows(Component, "screen-junk-card") != []

      UiKitHandler.uninstall_kit!(path, kit_name: "screen_junk")
    end
  end

  describe "uninstalling a bundle that no longer parses" do
    # RARE TRIGGER, CATASTROPHIC BLAST RADIUS. The fallback prefix was the literal "chelekom", so an
    # extension whose own bundle had stopped parsing called `ExtensionKit.uninstall!/1` on teardown
    # and purged Chelekom instead — hard-deleted through `:master_permanent_destroy`, which is
    # excluded from both the archive and PaperTrail. It returned `:ok` with no log line.
    test "purges by the bundle's filename, never by a guess", %{dir: dir} do
      keep =
        write!(dir, "keeper", %{
          "name" => "keeper",
          "components" => [
            %{"name" => "keeper-card", "type" => "general", "template" => "<div>k</div>"}
          ]
        })

      UiKitHandler.install_kit!(keep, site_id: nil)
      assert rows(Component, "keeper-card") != []

      corrupt = Path.join(dir, "ghostkit.json")
      File.write!(corrupt, "{ this is not json")

      assert :ok = UiKitHandler.uninstall_kit!(corrupt)

      assert rows(Component, "keeper-card") != [],
             "an unreadable bundle must not delete a kit it never named"

      UiKitHandler.uninstall_kit!(keep, kit_name: "keeper")
    end

    # When even the filename cannot serve — no name to slugify — refusing is the only safe answer.
    test "refuses when there is no name to purge by", %{dir: dir} do
      corrupt = Path.join(dir, ".json")
      File.write!(corrupt, "{ nope")

      assert {:error, {:unreadable_bundle, _reason}} = UiKitHandler.uninstall_kit!(corrupt)
    end

    test "an explicit :kit_name still wins over the filename", %{dir: dir} do
      path =
        write!(dir, "named", %{
          "name" => "named",
          "components" => [
            %{"name" => "named-card", "type" => "general", "template" => "<div>n</div>"}
          ]
        })

      UiKitHandler.install_kit!(path, site_id: nil)
      File.write!(path, "{ broken now")

      assert :ok = UiKitHandler.uninstall_kit!(path, kit_name: "named")
      assert rows(Component, "named-card") == []
    end
  end

  describe "a bundle whose rows are all fine" do
    test "installs every collection", %{dir: dir} do
      path =
        write!(dir, "screen_ok", %{
          "name" => "screen_ok",
          "components" => [
            %{"name" => "screen-ok-card", "type" => "general", "template" => "<div>c</div>"}
          ],
          "js_hooks" => [%{"name" => "ScreenOkHook", "content" => "export default {}"}],
          "stylesheets" => [
            %{"name" => "screen-ok-theme", "content" => "@theme {}", "kind" => "theme"}
          ]
        })

      UiKitHandler.install_kit!(path, site_id: nil)

      assert rows(Component, "screen-ok-card") != []
      assert rows(JsHook, "screenokhook") != []
      assert [sheet] = rows(Stylesheet, "screen-ok-theme")
      assert sheet.kind == :theme, "a kind the resource DOES have survives untouched"

      UiKitHandler.uninstall_kit!(path, kit_name: "screen_ok")
    end
  end
end
