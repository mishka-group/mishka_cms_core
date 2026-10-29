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

  Called once at boot by `MishkaCmsCore.Test.Boot` (its `js_assets:` option), before any test
  compiles JS. The directory is the one the suite's esbuild `NODE_PATH` names: core's own by default,
  an extension's under its own `priv/static/temp/js_assets/node_modules`.
  """

  @packages %{
    "phoenix" => "phoenix.cjs.js",
    "phoenix_html" => "phoenix_html.js",
    "phoenix_live_view" => "phoenix_live_view.cjs.js"
  }

  @doc """
  Writes a minimal package directory for each entry in `@packages` into `node_modules`, overwriting
  what is there. The bundles are read from the `deps/` of the project being tested.

  Raises when a dep is missing its prebuilt bundle: that means the dependency changed shape, and a
  silent skip would resurface as an esbuild resolution error much further from the cause.
  """
  @spec install!(Path.t()) :: :ok
  def install!(node_modules \\ default_node_modules()) do
    Enum.each(@packages, fn {package, bundle} ->
      source = Path.join([deps_path(), package, "priv", "static", bundle])

      if !File.exists?(source) do
        raise "#{package} no longer ships #{bundle} — update MishkaCmsCore.Test.JsAssets"
      end

      write_package!(Path.join(node_modules, package), package, source)
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  # `target` is the test suite's own `node_modules` directory and `source` a file under its `deps/`;
  # neither comes from a request.
  defp write_package!(target, package, source) do
    File.mkdir_p!(target)
    File.cp!(source, Path.join(target, "index.js"))

    File.write!(
      Path.join(target, "package.json"),
      Jason.encode!(%{name: package, version: "0.0.0", main: "index.js"})
    )
  end

  defp default_node_modules,
    do: Application.app_dir(:mishka_cms_core, "priv/static/temp/js_assets/node_modules")

  defp deps_path, do: Mix.Project.deps_path()
end
