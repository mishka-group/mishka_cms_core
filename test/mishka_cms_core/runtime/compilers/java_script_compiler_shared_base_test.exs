# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.JavaScriptCompilerSharedBaseTest do
  @moduledoc """
  Phase 4: the JS shared base (`app.js` + global hooks built once) and the
  reuse path for sites whose hooks are all global. Uses DataCase so the
  global-hooks query has a sandbox connection.
  """
  use MishkaCmsCore.DataCase, async: false
  @moduletag :integration

  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler, as: JS
  alias MishkaCmsCore.Runtime.States.AssetsState

  @base_id "__shared_base__"
  @site "shared_base_reuse_site"

  setup do
    Application.ensure_all_started(:mishka_cms)
    # Reuse is gated off under env_test?; flip it so compile_and_store/1 actually
    # takes the reuse path here (DataCase gives the global-hooks query a DB).
    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

    ensure_entry_modules_exist()
    JS.delete_shared_base_js()
    AssetsState.delete(@site, "js")
    AssetsState.delete(@site, "brotli_js")
    AssetsState.delete(@site, "gzip_js")

    on_exit(fn ->
      JS.delete_shared_base_js()
      AssetsState.delete(@site, "js")
      AssetsState.delete(@site, "brotli_js")
      AssetsState.delete(@site, "gzip_js")
    end)

    :ok
  end

  describe "compile_and_store_shared_base/0" do
    test "builds the base bundle once and stores all three formats" do
      assert {:ok, js} = JS.compile_and_store_shared_base()
      assert is_binary(js) and byte_size(js) > 0

      assert AssetsState.get_value(@base_id, "js") == js
      assert AssetsState.get_value(@base_id, "brotli_js") != nil
      assert AssetsState.get_value(@base_id, "gzip_js") != nil
    end
  end

  describe "get_or_compile_shared_base/0" do
    test "compiles on first call, then serves the cached bytes" do
      first = JS.get_or_compile_shared_base()
      assert byte_size(first) > 0
      assert AssetsState.get_value(@base_id, "js") == first

      # Second call must return the SAME cached bytes (no rebuild).
      assert JS.get_or_compile_shared_base() == first
    end
  end

  describe "compile_and_store/1 reuse path (site with no own hooks)" do
    test "serves the shared base bytes verbatim, skipping a per-site compile" do
      base = JS.get_or_compile_shared_base()

      assert {:ok, js} = JS.compile_and_store(@site)
      assert js == base
      assert JS.get_compiled_js(@site) == base
    end
  end

  describe "delete_shared_base_js/0" do
    test "clears all cached formats" do
      {:ok, _} = JS.compile_and_store_shared_base()
      assert AssetsState.get_value(@base_id, "js") != nil

      JS.delete_shared_base_js()

      assert AssetsState.get_value(@base_id, "js") == nil
      assert AssetsState.get_value(@base_id, "brotli_js") == nil
      assert AssetsState.get_value(@base_id, "gzip_js") == nil
    end
  end

  defp js_dir do
    case :code.priv_dir(:mishka_cms) do
      {:error, _} -> Path.join(["priv", "static", "temp", "js_assets", "js"])
      priv_dir -> Path.join([priv_dir, "static", "temp", "js_assets", "js"])
    end
  end

  # THE THREE MODULES THE GENERATED ENTRY IMPORTS. The compiler no longer rewrites `app.js` — it
  # writes a four-line entry that pulls in `boot`, `shared_hooks` and `site_hooks` — so those are
  # what a build needs on disk. Stubs are written only where nothing is checked in, and taken back
  # after, so a run that finds the real files uses them.
  defp ensure_entry_modules_exist do
    Enum.each(entry_module_stubs(), fn {name, source} ->
      path = Path.join(js_dir(), name)

      unless File.exists?(path) do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, source)
        on_exit(fn -> File.rm(path) end)
      end
    end)
  end

  defp entry_module_stubs do
    %{
      "boot.js" => """
      import { Socket } from "phoenix"
      import { LiveSocket } from "phoenix_live_view"

      export function boot(hooks) {
        const liveSocket = new LiveSocket("/live", Socket, { hooks })
        liveSocket.connect()
        window.liveSocket = liveSocket
      }
      """,
      "shared_hooks.js" => "export default {}\n",
      "site_hooks.js" => "export default {}\n"
    }
  end
end
