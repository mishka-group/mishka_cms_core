# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.JsAssets do
  @moduledoc """
  Provisions the `node_modules` tree esbuild resolves runtime JS bundles against.

  `MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler` emits an entry file that does
  `import { Socket } from "phoenix"`, and esbuild resolves those bare specifiers through `NODE_PATH`
  — `config/test.exs` points it at `priv/static/temp/js_assets/node_modules`. A host fills that
  directory as part of its asset build (the CMS keeps checked-in copies); running on our own, nothing
  does, and every JS compilation fails with `Could not resolve "phoenix"`.

  So the harness fills it from `deps/`, where each of these packages already ships a prebuilt CommonJS
  bundle — the same code the CMS vendored, read from the version this suite actually depends on rather
  than a copy that can drift. Only the packages the generated entry file imports are provisioned;
  `phoenix-colocated` is not among them because the compiler writes that one itself.

  Called once from `test_helper.exs`, before any test compiles JS.
  """

  @packages %{
    "phoenix" => "phoenix.cjs.js",
    "phoenix_html" => "phoenix_html.js",
    "phoenix_live_view" => "phoenix_live_view.cjs.js"
  }

  @doc """
  Writes a minimal package directory for each entry in `@packages`, overwriting what is there.

  Raises when a dep is missing its prebuilt bundle: that means the dependency changed shape, and a
  silent skip would resurface as an esbuild resolution error much further from the cause.
  """
  def install! do
    node_modules =
      :mishka_cms_core
      |> Application.app_dir("priv/static/temp/js_assets/node_modules")

    Enum.each(@packages, fn {package, bundle} ->
      source = Path.join([deps_path(), package, "priv", "static", bundle])

      if !File.exists?(source) do
        raise "#{package} no longer ships #{bundle} — update MishkaCmsCore.Test.JsAssets"
      end

      target = Path.join(node_modules, package)
      File.mkdir_p!(target)
      File.cp!(source, Path.join(target, "index.js"))

      File.write!(
        Path.join(target, "package.json"),
        Jason.encode!(%{name: package, version: "0.0.0", main: "index.js"})
      )
    end)
  end

  defp deps_path, do: Mix.Project.deps_path()
end
