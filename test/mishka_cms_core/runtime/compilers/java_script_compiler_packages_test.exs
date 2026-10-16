# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.JavaScriptCompilerPackagesTest do
  @moduledoc """
  A hook that imports npm packages and files of its own, built by the real esbuild against a registry
  this test answers — and the rest of the site still building when one hook's packages cannot be had,
  or when esbuild cannot build the hook itself.

  `async: false` — the registry is answered through `Application.put_env/3`, and the compile writes
  into the one shared `js_assets/` folder.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
  alias MishkaCmsCore.Runtime.{JsHook, RuntimeStatus}
  alias MishkaCmsCore.Runtime.States.AssetsState

  @reuse_site "lazy_reuse_site"

  setup do
    assets = js_assets_dir()
    js_dir = Path.join(assets, "js")
    File.mkdir_p!(js_dir)

    File.write!(Path.join(js_dir, "boot.js"), """
    import { Socket } from "phoenix"
    import { LiveSocket } from "phoenix_live_view"

    export function boot(hooks) {
      window.liveSocket = new LiveSocket("/live", Socket, { hooks })
    }
    """)

    File.write!(Path.join(js_dir, "shared_hooks.js"), "export default {}\n")
    File.write!(Path.join(js_dir, "site_hooks.js"), "export default {}\n")

    package = "mishka-test-chart-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf(Path.join([assets, "node_modules", package]))
      Application.delete_env(:mishka_cms_core, :npm_req_options)
    end)

    %{package: package}
  end

  defp js_assets_dir do
    case :code.priv_dir(Application.fetch_env!(:mishka_cms_core, :host_app)) do
      {:error, _} -> Path.join(["priv", "static", "temp", "js_assets"])
      priv_dir -> Path.join([priv_dir, "static", "temp", "js_assets"])
    end
  end

  defp tarball(name, marker),
    do: package(name, "export default function draw() { return #{inspect(marker)}; }")

  defp package(name, index) do
    path = Path.join(System.tmp_dir!(), "pkg_#{System.unique_integer([:positive])}.tgz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [
          {~c"package/package.json", ~s({"name": "#{name}", "main": "index.js"})},
          {~c"package/index.js", index}
        ],
        [:compressed]
      )

    tgz = File.read!(path)
    File.rm!(path)
    tgz
  end

  defp entry(name, tgz) do
    %{
      "name" => name,
      "version" => "1.0.0",
      "path" => "node_modules/#{name}",
      "integrity" => "sha512-" <> Base.encode64(:crypto.hash(:sha512, tgz))
    }
  end

  defp registry!(tarballs) do
    Application.put_env(:mishka_cms_core, :npm_req_options,
      plug: fn conn ->
        case Map.fetch(tarballs, conn.request_path) do
          {:ok, tgz} -> Plug.Conn.send_resp(conn, 200, tgz)
          :error -> Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      end
    )
  end

  defp hook!(name, content, attrs) do
    JsHook
    |> Ash.Changeset.for_create(
      :master_create,
      Map.merge(%{name: name, content: content}, attrs),
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  test "a hook's packages and its own files are built into the site's JavaScript", %{
    package: package
  } do
    tgz = tarball(package, "DRAWN_BY_THE_PACKAGE")
    registry!(%{"/#{package}/-/#{package}-1.0.0.tgz" => tgz})

    hook!(
      "chart",
      """
      import draw from "#{package}";
      import settings from "./chart_extensions.js";
      export default { mounted() { window.__chart = [draw(), settings.palette]; } };
      """,
      %{
        npm: [entry(package, tgz)],
        modules: [
          %{
            "file" => "chart_extensions.js",
            "content" => ~s(export default { palette: "SITE_PALETTE" };)
          }
        ]
      }
    )

    assert {:ok, %{js: js}} = JavaScriptCompiler.compile("packages_site", global_only: true)
    assert js =~ "DRAWN_BY_THE_PACKAGE"
    assert js =~ "SITE_PALETTE"
  end

  # ONE UNRESOLVED IMPORT FAILED THE WHOLE BUNDLE, and that bundle starts every page's live
  # connection. The hook is left out; every other hook is built.
  test "a hook whose packages cannot be had is left out, and the rest still build", %{
    package: package
  } do
    registry!(%{})

    hook!(
      "chart",
      ~s|import draw from "#{package}"; export default { mounted() { draw("CHART_HOOK"); } };|,
      %{npm: [entry(package, tarball(package, "X"))]}
    )

    hook!("toast", ~s|export default { mounted() { window.__toast = "TOAST_HOOK"; } };|, %{})

    assert {:ok, %{js: js}} = JavaScriptCompiler.compile("packages_site", global_only: true)
    assert js =~ "TOAST_HOOK"
    refute js =~ "CHART_HOOK"
  end

  defp left_out!(site \\ "packages_site") do
    assert {:ok, %{js: js}} = JavaScriptCompiler.compile(site, global_only: true)
    assert js =~ "TOAST_HOOK", "every other hook is still built"
    refute js =~ "CHART_HOOK"
    js
  end

  defp left_out_of_site(hook) do
    hook.id |> JavaScriptCompiler.left_out() |> Map.new() |> Map.get("packages_site")
  end

  describe "a hook esbuild cannot build" do
    setup do
      hook!("toast", ~s|export default { mounted() { window.__toast = "TOAST_HOOK"; } };|, %{})
      :ok
    end

    test "is left out when it imports a package it does not declare", %{package: package} do
      chart =
        hook!(
          "chart",
          ~s|import draw from "#{package}"; export default { mounted() { draw("CHART_HOOK"); } };|,
          %{}
        )

      left_out!()

      assert left_out_of_site(chart) =~
               ~s(Could not resolve "#{package}")
    end

    test "is left out when it imports a file of its own it does not carry" do
      chart =
        hook!(
          "chart",
          ~s|import settings from "./chart_extensions.js"; export default { mounted() { window.__chart = [settings, "CHART_HOOK"]; } };|,
          %{}
        )

      left_out!()

      assert left_out_of_site(chart) =~
               ~s(Could not resolve "./chart_extensions.js")
    end

    test "is left out when its own code does not parse" do
      chart =
        hook!(
          "chart",
          ~s|export default { mounted() { let = ; window.__chart = "CHART_HOOK"; } };|,
          %{}
        )

      left_out!()

      assert left_out_of_site(chart) =~ "Unexpected"
    end

    test "is left out when a file of its own does not parse" do
      chart =
        hook!(
          "chart",
          ~s|import settings from "./chart_extensions.js"; export default { mounted() { window.__chart = [settings, "CHART_HOOK"]; } };|,
          %{modules: [%{"file" => "chart_extensions.js", "content" => "export default {"}]}
        )

      left_out!()

      assert left_out_of_site(chart) =~
               "chart_extensions.js"
    end

    test "is left out when a package it declares imports one its tree does not carry", %{
      package: package
    } do
      tgz =
        package(package, ~s|import missing from "#{package}-dependency"; export default missing;|)

      registry!(%{"/#{package}/-/#{package}-1.0.0.tgz" => tgz})

      chart =
        hook!(
          "chart",
          ~s|import draw from "#{package}"; export default { mounted() { draw("CHART_HOOK"); } };|,
          %{npm: [entry(package, tgz)]}
        )

      left_out!()

      assert left_out_of_site(chart) =~
               ~s(Could not resolve "#{package}-dependency")
    end

    test "is built again once it is fixed, and its reason is gone" do
      chart = hook!("chart", ~s|export default { mounted() { let = ; } };|, %{})

      left_out!()
      assert left_out_of_site(chart)

      chart
      |> Ash.Changeset.for_update(
        :master_update,
        %{content: ~s|export default { mounted() { window.__chart = "CHART_HOOK"; } };|},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      assert {:ok, %{js: js}} = JavaScriptCompiler.compile("packages_site", global_only: true)
      assert js =~ "CHART_HOOK"
      assert js =~ "TOAST_HOOK"
      assert left_out_of_site(chart) == nil
    end

    test "is reported on its runtime status rather than as live" do
      chart = hook!("chart", ~s|import "./nowhere.js"; export default {};|, %{})

      left_out!()

      status = RuntimeStatus.compute(chart, JsHook)

      assert status.state == :failed
      assert status.label == "Left out of the bundle"
      assert status.message =~ "packages_site"
      assert status.message =~ ~s(Could not resolve "./nowhere.js")
    end

    test "does not hide an error in the code every site shares, nor forget what was left out" do
      chart = hook!("chart", ~s|export default { mounted() { let = ; } };|, %{})
      left_out!()
      reported = left_out_of_site(chart)

      boot = Path.join([js_assets_dir(), "js", "boot.js"])
      original = File.read!(boot)
      on_exit(fn -> File.write!(boot, original) end)
      File.write!(boot, "export function boot( {")

      assert {:error, reason} = JavaScriptCompiler.compile("packages_site", global_only: true)
      assert reason =~ "Esbuild compilation failed"
      assert reason =~ "boot.js"
      assert left_out_of_site(chart) == reported, "the bundle still served is the one reported"
    end
  end

  describe "a lazy hook" do
    setup %{package: package} do
      tgz = tarball(package, "DRAWN_BY_THE_HEAVY_PACKAGE")
      registry!(%{"/#{package}/-/#{package}-1.0.0.tgz" => tgz})

      hook!("toast", ~s|export default { mounted() { window.__toast = "TOAST_HOOK"; } };|, %{})

      chart =
        hook!(
          "chart",
          """
          import draw from "#{package}";
          import settings from "./chart_extensions.js";
          export default { mounted() { window.__chart = [draw(), settings.palette]; } };
          """,
          %{
            lazy: true,
            npm: [entry(package, tgz)],
            modules: [
              %{
                "file" => "chart_extensions.js",
                "content" => ~s(export default { palette: "SITE_PALETTE" };)
              }
            ]
          }
        )

      Application.put_env(:mishka_cms_core, :env_test?, false)

      on_exit(fn ->
        Application.put_env(:mishka_cms_core, :env_test?, true)
        JavaScriptCompiler.delete_shared_base_js()
        Enum.each(AssetsState.types(@reuse_site), &AssetsState.delete(@reuse_site, &1))
      end)

      %{chart: chart}
    end

    test "is built as its own module, and the bundle carries the stub that loads it instead" do
      assert {:ok, %{js: js, lazy: [module]}} =
               JavaScriptCompiler.compile("packages_site", global_only: true)

      assert module.hook == "chart"
      assert module.hash == Base.encode16(:crypto.hash(:md5, module.js), case: :lower)
      assert module.js =~ "DRAWN_BY_THE_HEAVY_PACKAGE"
      assert module.js =~ "SITE_PALETTE"
      assert module.js =~ ~r/export\s*\{[^}]*as default\s*\}/

      refute js =~ "DRAWN_BY_THE_HEAVY_PACKAGE"
      refute js =~ "SITE_PALETTE"
      assert js =~ "#{module.hash}.js"
      assert js =~ "GlobalChart"
      assert js =~ "TOAST_HOOK"
    end

    test "that does not build is left out, and the rest still build", %{chart: chart} do
      chart
      |> Ash.Changeset.for_update(
        :master_update,
        %{content: ~s|export default { mounted() { let = ; window.__chart = "CHART_HOOK"; } };|},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      assert {:ok, %{js: js, lazy: []}} =
               JavaScriptCompiler.compile("packages_site", global_only: true)

      assert js =~ "TOAST_HOOK"
      refute js =~ "GlobalChart"
      assert left_out_of_site(chart) =~ "Unexpected"
    end

    test "is stored with the bundle that loads it, copied with the shared base, and dropped with it",
         %{chart: chart} do
      assert {:ok, base} = JavaScriptCompiler.compile_and_store_shared_base()
      assert [hash] = lazy_hashes("__shared_base__")
      assert base =~ "#{hash}.js"

      for type <- [lazy(hash), "brotli_" <> lazy(hash), "gzip_" <> lazy(hash)] do
        assert %{hash: ^hash, value: value} = AssetsState.get!("__shared_base__", type)
        assert byte_size(value) > 0
      end

      assert AssetsState.get_value("__shared_base__", lazy(hash)) =~ "DRAWN_BY_THE_HEAVY_PACKAGE"

      # A site whose hooks are all global serves a copy of the base, and its stubs read their
      # module beside that copy.
      assert {:ok, ^base} = JavaScriptCompiler.compile_and_store(@reuse_site)
      assert lazy_hashes(@reuse_site) == [hash]

      chart =
        chart
        |> Ash.Changeset.for_update(:master_update, %{lazy: false}, authorize?: false)
        |> Ash.update!(authorize?: false)

      assert {:ok, eager} = JavaScriptCompiler.compile_and_store_shared_base()
      assert eager =~ "DRAWN_BY_THE_HEAVY_PACKAGE"
      assert lazy_hashes("__shared_base__") == []

      assert {:ok, ^eager} = JavaScriptCompiler.compile_and_store(@reuse_site)
      assert lazy_hashes(@reuse_site) == []

      chart
      |> Ash.Changeset.for_update(:master_update, %{lazy: true}, authorize?: false)
      |> Ash.update!(authorize?: false)

      assert {:ok, base} = JavaScriptCompiler.compile_and_store_shared_base()
      assert [hash] = lazy_hashes("__shared_base__")
      assert {:ok, ^base} = JavaScriptCompiler.compile_and_store(@reuse_site)
      assert lazy_hashes(@reuse_site) == [hash]

      JavaScriptCompiler.delete_shared_base_js()
      assert lazy_types("__shared_base__") == []
      assert lazy_hashes(@reuse_site) == [hash], "a site's copy goes with its own bundle"
    end
  end

  defp lazy(hash), do: JavaScriptCompiler.lazy_type(hash)

  defp lazy_hashes(id) do
    for "lazy_js:" <> hash <- AssetsState.types(id), do: hash
  end

  defp lazy_types(id), do: Enum.filter(AssetsState.types(id), &(&1 =~ "lazy_js:"))

  test "a package or a module that cannot be fetched or written is refused when the hook is saved" do
    refused =
      JsHook
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "chart",
          content: "export default {};",
          modules: [%{"file" => "../../escape.js", "content" => "x"}]
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} = refused

    refused =
      JsHook
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "chart",
          content: "export default {};",
          npm: [%{"name" => "echarts", "version" => "^6", "path" => "x", "integrity" => "y"}]
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} = refused
  end
end
