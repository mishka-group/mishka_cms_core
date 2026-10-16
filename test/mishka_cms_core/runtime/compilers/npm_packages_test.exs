# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.NpmPackagesTest do
  @moduledoc """
  A hook's npm packages, fetched from a registry this test answers, once, and only when they are
  what the hook pinned.

  `async: false` — the registry is answered through `Application.put_env/3`.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Compilers.NpmPackages

  setup do
    root = Path.join(System.tmp_dir!(), "npm_packages_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.delete_env(:mishka_cms_core, :npm_req_options)
    end)

    %{root: root}
  end

  # A packed npm package: every file under `package/`, as `npm pack` writes it.
  defp tarball(files) do
    path = Path.join(System.tmp_dir!(), "pkg_#{System.unique_integer([:positive])}.tgz")
    entries = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    tgz = File.read!(path)
    File.rm!(path)
    tgz
  end

  defp integrity(tgz), do: "sha512-" <> Base.encode64(:crypto.hash(:sha512, tgz))

  defp entry(name, version, tgz, path \\ nil) do
    %{
      "name" => name,
      "version" => version,
      "path" => path || "node_modules/#{name}",
      "integrity" => integrity(tgz)
    }
  end

  # The registry: `tarballs` keyed by request path; every request is reported to the test.
  defp registry!(tarballs) do
    test = self()

    Application.put_env(:mishka_cms_core, :npm_req_options,
      plug: fn conn ->
        send(test, {:fetched, conn.request_path})

        case Map.fetch(tarballs, conn.request_path) do
          {:ok, tgz} -> Plug.Conn.send_resp(conn, 200, tgz)
          :error -> Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      end
    )
  end

  defp package_tgz(name, marker),
    do:
      tarball([
        {"package/package.json", ~s({"name": "#{name}", "main": "index.js"})},
        {"package/index.js", "export default #{inspect(marker)};"},
        {"package/lib/util.js", "export const util = 1;"}
      ])

  test "a package is fetched, checked and unpacked where its path says", %{root: root} do
    tgz = package_tgz("charts", "CHARTS")
    registry!(%{"/charts/-/charts-6.1.0.tgz" => tgz})

    assert :ok = NpmPackages.ensure([entry("charts", "6.1.0", tgz)], root)

    package = Path.join(root, "node_modules/charts")
    assert File.read!(Path.join(package, "index.js")) == ~s(export default "CHARTS";)
    assert File.read!(Path.join(package, "lib/util.js")) == "export const util = 1;"
    assert_received {:fetched, "/charts/-/charts-6.1.0.tgz"}
  end

  # ONCE: a compile with every package in place asks the registry nothing.
  test "a package in place is not fetched again", %{root: root} do
    tgz = package_tgz("charts", "CHARTS")
    registry!(%{"/charts/-/charts-6.1.0.tgz" => tgz})
    packages = [entry("charts", "6.1.0", tgz)]

    assert :ok = NpmPackages.ensure(packages, root)
    assert_received {:fetched, _path}

    assert :ok = NpmPackages.ensure(packages, root)
    refute_received {:fetched, _path}
  end

  test "a newer pin replaces the version this module placed", %{root: root} do
    old = package_tgz("charts", "OLD")
    new = package_tgz("charts", "NEW")

    registry!(%{
      "/charts/-/charts-6.0.0.tgz" => old,
      "/charts/-/charts-6.1.0.tgz" => new
    })

    assert :ok = NpmPackages.ensure([entry("charts", "6.0.0", old)], root)
    assert :ok = NpmPackages.ensure([entry("charts", "6.1.0", new)], root)

    assert File.read!(Path.join(root, "node_modules/charts/index.js")) =~ "NEW"
  end

  test "a scoped package, and one nested under another", %{root: root} do
    core = package_tgz("@tiptap/core", "CORE")
    nested = package_tgz("lib", "NESTED")

    registry!(%{
      "/@tiptap/core/-/core-3.28.0.tgz" => core,
      "/lib/-/lib-2.0.0.tgz" => nested
    })

    assert :ok =
             NpmPackages.ensure(
               [
                 entry("lib", "2.0.0", nested, "node_modules/@tiptap/core/node_modules/lib"),
                 entry("@tiptap/core", "3.28.0", core)
               ],
               root
             )

    assert File.read!(Path.join(root, "node_modules/@tiptap/core/index.js")) =~ "CORE"

    assert File.read!(Path.join(root, "node_modules/@tiptap/core/node_modules/lib/index.js")) =~
             "NESTED"
  end

  test "a download that is not what was pinned is refused, and nothing is written", %{root: root} do
    pinned = package_tgz("charts", "PINNED")
    served = package_tgz("charts", "SOMETHING ELSE")
    registry!(%{"/charts/-/charts-6.1.0.tgz" => served})

    assert {:error, "charts@6.1.0: the download does not match its integrity hash"} =
             NpmPackages.ensure([entry("charts", "6.1.0", pinned)], root)

    assert File.ls!(root) == []
  end

  test "an archive with a file outside its package is refused whole", %{root: root} do
    tgz =
      tarball([
        {"package/index.js", "export default 1;"},
        {"package/../../escape.js", "export default 2;"}
      ])

    registry!(%{"/charts/-/charts-6.1.0.tgz" => tgz})

    assert {:error, "charts@6.1.0: the archive holds " <> _} =
             NpmPackages.ensure([entry("charts", "6.1.0", tgz)], root)

    refute File.exists?(Path.join(root, "node_modules/charts"))
    refute File.exists?(Path.join(System.tmp_dir!(), "escape.js"))
  end

  test "an entry that is not a fetchable package is refused before any request", %{root: root} do
    tgz = package_tgz("charts", "X")
    registry!(%{})
    good = entry("charts", "6.1.0", tgz)

    for bad <- [
          %{good | "name" => "../charts"},
          %{good | "version" => "^6.1.0"},
          %{good | "path" => "node_modules/other"},
          %{good | "path" => "node_modules/../../charts"},
          %{good | "path" => "/etc/charts"},
          %{good | "integrity" => "sha1-abc"},
          Map.delete(good, "integrity"),
          "charts@6.1.0"
        ] do
      assert {:error, reason} = NpmPackages.ensure([bad], root)
      assert reason =~ "is not a package this CMS can fetch"
    end

    refute_received {:fetched, _path}
    assert File.ls!(root) == []
  end

  # A folder this module did not write — a package the CMS provisions itself — is never replaced.
  test "a package the CMS provides itself is used as it is", %{root: root} do
    provided = Path.join(root, "node_modules/phoenix")
    File.mkdir_p!(provided)
    File.write!(Path.join(provided, "index.js"), "PROVIDED")
    registry!(%{})

    assert :ok =
             NpmPackages.ensure([entry("phoenix", "1.8.0", package_tgz("phoenix", "X"))], root)

    assert File.read!(Path.join(provided, "index.js")) == "PROVIDED"
    refute_received {:fetched, _path}
  end

  test "a package the registry does not have is named with the answer", %{root: root} do
    registry!(%{})

    assert {:error, "charts@6.1.0: the registry answered HTTP 404"} =
             NpmPackages.ensure([entry("charts", "6.1.0", package_tgz("charts", "X"))], root)
  end

  test "no packages is nothing to do" do
    assert NpmPackages.ensure([], "/nowhere") == :ok
    assert NpmPackages.ensure(nil, "/nowhere") == :ok
  end
end
