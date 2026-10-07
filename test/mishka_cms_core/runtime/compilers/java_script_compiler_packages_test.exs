defmodule MishkaCmsCore.Runtime.Compilers.JavaScriptCompilerPackagesTest do
  @moduledoc """
  A hook that imports npm packages and files of its own, built by the real esbuild against a registry
  this test answers — and the rest of the site still building when one hook's packages cannot be had.

  `async: false` — the registry is answered through `Application.put_env/3`, and the compile writes
  into the one shared `js_assets/` folder.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
  alias MishkaCmsCore.Runtime.JsHook

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

  defp tarball(name, marker) do
    path = Path.join(System.tmp_dir!(), "pkg_#{System.unique_integer([:positive])}.tgz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [
          {~c"package/package.json", ~s({"name": "#{name}", "main": "index.js"})},
          {~c"package/index.js", "export default function draw() { return #{inspect(marker)}; }"}
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

    assert {:ok, js} = JavaScriptCompiler.compile("packages_site", global_only: true)
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

    assert {:ok, js} = JavaScriptCompiler.compile("packages_site", global_only: true)
    assert js =~ "TOAST_HOOK"
    refute js =~ "CHART_HOOK"
  end

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
