# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.JavaScriptCompilerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MishkaCmsCore.Runtime.Compilers.{Helpers, JavaScriptCompiler}
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Test.EventCannotRun
  @moduletag :unit

  setup_all do
    # Setup test environment
    Application.ensure_all_started(:mishka_cms)
    :ok
  end

  setup do
    # Clean up any existing assets for test sites
    AssetsState.delete("test_site", "js")
    AssetsState.delete("test_site", "brotli_js")
    AssetsState.delete("test_site", "gzip_js")
    AssetsState.delete("empty_site", "js")

    # Clear the persistent_term for esbuild verification to test ensure_installed
    :persistent_term.erase(:mishka_cms_esbuild_verified)

    # Ensure the app.js file exists in the proper location
    ensure_entry_modules_exist()

    on_exit(fn ->
      # Cleanup test assets
      AssetsState.delete("test_site", "js")
      AssetsState.delete("test_site", "brotli_js")
      AssetsState.delete("test_site", "gzip_js")
      # A failed build is recorded beside the bundles (`Helpers.record_asset_build/3`), and this
      # module is not a DataCase, whose cleanup would forget it.
      MishkaCmsCore.Runtime.Compilers.Helpers.forget_asset_builds("test_site")
    end)

    :ok
  end

  describe "ensure_installed/0" do
    test "returns :ok and verifies ESBuild binary" do
      assert JavaScriptCompiler.ensure_installed() == :ok
    end

    # The assertion the three tests around this one cannot make. A compile shells out to the binary,
    # so `System.cmd` answers a missing one with `ErlangError :enoent` — an error naming nothing,
    # under a log line that used to claim the binary had been found. It claimed that because the old
    # check asked `Esbuild.bin_path/0`, which BUILDS a path string and hands it back whether or not
    # a file is there; `:ok` and the cache flag were both perfectly true with no esbuild on disk.
    # `bin_version/0` runs the file, so this passes only if something is really there — and only if
    # it is the version this project pinned, not one left behind by another.
    test "leaves the configured esbuild version installed and runnable" do
      assert :ok = JavaScriptCompiler.ensure_installed()

      assert Esbuild.bin_version() == {:ok, Esbuild.configured_version()}
    end

    test "caches verification result in persistent_term" do
      :persistent_term.erase(:mishka_cms_esbuild_verified)
      assert :persistent_term.get(:mishka_cms_esbuild_verified, false) == false

      JavaScriptCompiler.ensure_installed()

      assert :persistent_term.get(:mishka_cms_esbuild_verified, false) == true
    end

    test "skips verification if already verified" do
      :persistent_term.put(:mishka_cms_esbuild_verified, true)

      log_output =
        capture_log([level: :info], fn ->
          assert JavaScriptCompiler.ensure_installed() == :ok
        end)

      refute log_output =~ "Verifying ESBuild binary"
    end
  end

  describe "compile/1" do
    test "successfully compiles JavaScript for a site with no hooks" do
      assert {:ok, %{js: js}} = JavaScriptCompiler.compile("test_site")
      assert is_binary(js)
      assert byte_size(js) > 0
      # Should contain some basic JavaScript structure
      # IIFE wrapper
      assert String.contains?(js, "(")
      assert String.contains?(js, ")")
    end

    test "successfully compiles JavaScript for a site that doesn't exist" do
      # When site doesn't exist, it should still compile with empty hooks
      assert {:ok, %{js: js}} = JavaScriptCompiler.compile("nonexistent_site")
      assert is_binary(js)
      assert byte_size(js) > 0
    end

    # A MISSING ENTRY MODULE MUST FAIL THE BUILD, not produce a bundle without it. The entry is
    # generated now — four imports — so the thing that can be absent is one of the modules it names,
    # and esbuild is what notices.
    test "a missing entry module fails the compile rather than shipping a bundle without it" do
      remove_entry_module("boot.js")

      assert {:error, reason} = JavaScriptCompiler.compile("test_site")
      assert String.contains?(reason, "Esbuild compilation failed")

      ensure_entry_modules_exist()
    end

    test "cleans up temporary files after compilation" do
      temp_dir = get_temp_dir()
      js_dir = Path.join([temp_dir, "js_assets", "js"])

      # Clean up any leftover entry files from previous tests first
      case File.ls(js_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.starts_with?(&1, "entry_"))
          |> Enum.each(&File.rm(Path.join(js_dir, &1)))

        {:error, _} ->
          :ok
      end

      # Compile and check cleanup happens
      assert {:ok, %{js: _js}} = JavaScriptCompiler.compile("test_site")

      # The implementation should clean up temporary files
      # We can verify by checking the temp directory pattern
      # Check for leftover entry files
      case File.ls(js_dir) do
        {:ok, files} ->
          entry_files = Enum.filter(files, &String.starts_with?(&1, "entry_"))
          assert Enum.empty?(entry_files), "Temporary entry files should be cleaned up"

        {:error, _} ->
          # Directory doesn't exist yet, which is fine
          :ok
      end
    end
  end

  describe "compile_and_store/1" do
    test "successfully compiles and stores JavaScript with compression" do
      assert {:ok, js} = JavaScriptCompiler.compile_and_store("test_site")
      assert is_binary(js)

      # Check that all versions are stored
      assert AssetsState.get_value("test_site", "js") == js
      assert AssetsState.get_value("test_site", "brotli_js") != nil
      assert AssetsState.get_value("test_site", "gzip_js") != nil
    end

    test "stores the bundle while runtime:compile:js cannot run" do
      EventCannotRun.stub!("runtime:compile:js")

      assert {:ok, js} = JavaScriptCompiler.compile_and_store("test_site")
      assert is_binary(js) and byte_size(js) > 0
      assert AssetsState.get_value("test_site", "js") == js
    end

    test "stores JavaScript successfully" do
      assert {:ok, js} = JavaScriptCompiler.compile_and_store("test_site")

      # Get the stored value directly
      stored_js = AssetsState.get_value("test_site", "js")
      assert stored_js == js
      assert is_binary(stored_js)
      assert byte_size(stored_js) > 0
    end

    test "logs compilation success at debug level" do
      # Configure logger to capture debug level
      Logger.configure(level: :debug)

      log_output =
        capture_log([level: :debug], fn ->
          assert {:ok, _js} = JavaScriptCompiler.compile_and_store("test_site")
        end)

      assert log_output =~ "JavaScript compiled and stored in AssetsState for site: test_site"

      # Reset log level
      Logger.configure(level: :info)
    end

    test "logs compilation failure" do
      # Remove a module the generated entry imports, to make the build fail.
      remove_entry_module("boot.js")

      log_output =
        capture_log(fn ->
          assert {:error, _reason} = JavaScriptCompiler.compile_and_store("test_site")
        end)

      assert log_output =~ "Failed to compile JavaScript for site test_site"

      ensure_entry_modules_exist()
    end

    # A BROKEN BUILD IS RECORDED, beside the bundle it did not replace, so the editor and the JS
    # Hooks page can say the latest change is not live; the next build that works forgets it.
    test "records a failed build, and forgets it once a build works" do
      on_exit(fn -> Helpers.forget_asset_builds("test_site") end)

      assert {:ok, _js} = JavaScriptCompiler.compile_and_store("test_site")
      assert Helpers.asset_build_failure("test_site", "js") == nil
      good = AssetsState.get_value("test_site", "js")

      remove_entry_module("boot.js")

      capture_log(fn ->
        assert {:error, _reason} = JavaScriptCompiler.compile_and_store("test_site")
      end)

      ensure_entry_modules_exist()

      assert %{served: :last_good, reason: reason} =
               Helpers.asset_build_failure("test_site", "js")

      assert reason =~ "Esbuild compilation failed"

      assert AssetsState.get_value("test_site", "js") == good,
             "the broken build replaced the bundle"

      assert {:ok, _js} = JavaScriptCompiler.compile_and_store("test_site")
      assert Helpers.asset_build_failure("test_site", "js") == nil
    end
  end

  describe "get_compiled_js/1" do
    test "returns compiled JavaScript when it exists" do
      assert {:ok, original_js} = JavaScriptCompiler.compile_and_store("test_site")
      retrieved_js = JavaScriptCompiler.get_compiled_js("test_site")

      assert retrieved_js == original_js
    end

    test "returns fallback comment when JavaScript doesn't exist" do
      fallback = JavaScriptCompiler.get_compiled_js("nonexistent_site")
      assert fallback == "// JS not found for site: nonexistent_site"
    end
  end

  describe "js_exists?/1" do
    test "returns true when JavaScript exists" do
      assert {:ok, _js} = JavaScriptCompiler.compile_and_store("test_site")
      assert JavaScriptCompiler.js_exists?("test_site") == true
    end

    test "returns false when JavaScript doesn't exist" do
      assert JavaScriptCompiler.js_exists?("nonexistent_site") == false
    end
  end

  describe "delete_compiled_js/1" do
    test "successfully deletes compiled JavaScript" do
      assert {:ok, _js} = JavaScriptCompiler.compile_and_store("test_site")
      assert JavaScriptCompiler.js_exists?("test_site") == true

      JavaScriptCompiler.delete_compiled_js("test_site")
      assert JavaScriptCompiler.js_exists?("test_site") == false
    end
  end

  describe "refresh_js/1" do
    test "recompiles and updates stored JavaScript" do
      # Initial compilation
      assert {:ok, _original_js} = JavaScriptCompiler.compile_and_store("test_site")

      # Temporarily set logger level to info for this test
      original_level = Logger.level()
      Logger.configure(level: :info)

      # Refresh and capture info level log
      log_output =
        capture_log([level: :info], fn ->
          assert {:ok, refreshed_js} = JavaScriptCompiler.refresh_js("test_site")
          assert is_binary(refreshed_js)
        end)

      # Restore original logger level
      Logger.configure(level: original_level)

      assert log_output =~ "Refreshing JS for site: test_site"

      # Check that it was recompiled
      stored_js = AssetsState.get_value("test_site", "js")
      assert stored_js != nil
    end
  end

  # Helper functions for testing

  # THE THREE MODULES THE GENERATED ENTRY IMPORTS. The compiler writes a four-line entry that pulls
  # in `boot`, `shared_hooks` and `site_hooks`; it no longer reads and rewrites `app.js`, so those
  # are what has to exist for a build to succeed.
  defp ensure_entry_modules_exist do
    js_dir = Path.join(get_js_assets_dir(), "js")
    File.mkdir_p!(js_dir)

    boot = """
    import { Socket } from "phoenix"
    import { LiveSocket } from "phoenix_live_view"

    export function boot(hooks) {
      const liveSocket = new LiveSocket("/live", Socket, { hooks })
      liveSocket.connect()
      window.liveSocket = liveSocket
    }
    """

    File.write!(Path.join(js_dir, "boot.js"), boot)
    File.write!(Path.join(js_dir, "shared_hooks.js"), "export default {}\n")
    File.write!(Path.join(js_dir, "site_hooks.js"), "export default {}\n")
  end

  defp remove_entry_module(name) do
    File.rm(Path.join([get_js_assets_dir(), "js", name]))
  end

  defp get_js_assets_dir do
    # Match the logic from the actual compiler
    case :code.priv_dir(:mishka_cms) do
      {:error, _} -> Path.join(["priv", "static", "temp", "js_assets"])
      priv_dir -> Path.join([priv_dir, "static", "temp", "js_assets"])
    end
  end

  defp get_temp_dir do
    # Match the logic from the actual compiler
    case :code.priv_dir(:mishka_cms) do
      {:error, _} -> Path.join(["priv", "static", "temp"])
      priv_dir -> Path.join([priv_dir, "static", "temp"])
    end
  end
end
