defmodule MishkaCmsCore.Runtime.Handlers.UiKitSourcesTest do
  @moduledoc """
  Where the first-run installer gets its packages from, and what happens when one of them cannot be
  reached.

  `/install` runs once on a fresh CMS and is the only place this system fetches a package from
  outside itself. No version is written in the code: Chelekom's packages are taken from the newest
  release that attaches them — stable unless the operator picks a pre-release or `master` — and a
  host that wants exact files names them in config.

  What must not move is that the version is found rather than written down, that the one fetched is
  named, that a kit resolves from disk before the network, and that one package failing leaves the
  others installable.

  `async: false` — `Application.put_env/3` is global.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  setup do
    original = Application.get_env(:mishka_cms_core, :official_ui_kits)

    prefer = Application.get_env(:mishka_cms_core, :prefer_local_ui_kits)

    on_exit(fn ->
      restore_official_kits(original)
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, prefer)
      Application.delete_env(:mishka_cms_core, :ui_kit_req_options)
    end)

    # THE PACKAGES THE LIBRARY SHIPS, not the offline list `config/test.exs` narrows them to. The
    # shape assertions below are about what a host gets without configuring anything.
    Application.delete_env(:mishka_cms_core, :official_ui_kits)
    shipped = UiKitHandler.packages()
    restore_official_kits(original)

    # A TEMP KITS DIRECTORY. The shipped `priv/cms_ui_kits/chelekom.json` is real and 8.6 MB, and
    # `resolve_kits/1` picks up everything in the directory by design — so a fixture written beside
    # it would be joined by the real kit and every assertion here would pass or fail for a reason
    # that has nothing to do with what it is testing.
    dir = Path.join(System.tmp_dir!(), "ui_kit_sources_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{original: original, shipped: shipped, dir: dir}
  end

  defp restore_official_kits(nil), do: Application.delete_env(:mishka_cms_core, :official_ui_kits)

  defp restore_official_kits(list),
    do: Application.put_env(:mishka_cms_core, :official_ui_kits, list)

  defp bundle(name, components \\ []) do
    %{"$schema" => "mishka.ui_kit.bundle.v3", "name" => name, "components" => components}
  end

  defp place!(dir, file, bundle) do
    path = Path.join(dir, file)
    File.write!(path, Jason.encode!(bundle))
    path
  end

  describe "the configured sources" do
    # A VERSION WRITTEN HERE WAS A VERSION EVERY RELEASE HAD TO EDIT. The packages say which files to
    # fetch; which release they come from is found when they are fetched.
    test "the shipped packages name their files and no version", %{shipped: shipped} do
      refute shipped == [], "the shipped default must offer at least one package"

      for package <- shipped do
        assert is_binary(package.label) and package.label != ""
        assert Path.extname(package.file) == ".json"
        refute Map.has_key?(package, :tag), "#{inspect(package.key)} names a version"
        refute Map.has_key?(package, :url), "#{inspect(package.key)} names a download"
      end
    end

    test "both official packages are offered", %{shipped: configured} do
      keys = Enum.map(configured, & &1[:key])

      assert :styled in keys
      assert :headless in keys
    end

    test "config replaces the shipped list wholesale" do
      Application.put_env(:mishka_cms_core, :official_ui_kits, [
        %{
          key: :acme,
          label: "Acme",
          file: "acme.json",
          tag: "v9",
          url: "https://example.test/a.json"
        }
      ])

      assert [%{key: :acme, tag: "v9"}] = UiKitHandler.official_kits()
      assert [%{key: :acme}] = UiKitHandler.packages()
      assert UiKitHandler.configured?()
    end

    # An air-gapped install has no source to download from and must still work off the directory.
    test "an empty list is a valid configuration" do
      Application.put_env(:mishka_cms_core, :official_ui_kits, [])

      assert UiKitHandler.official_kits() == []
      assert UiKitHandler.configured?()
    end
  end

  # WHICH RELEASE. GitHub lists a repository's releases newest first, each marked a pre-release or
  # not and carrying the files attached to it; a draft is not published.
  describe "finding the release" do
    setup do
      Application.delete_env(:mishka_cms_core, :official_ui_kits)
      :ok
    end

    defp release(tag, opts) do
      files = Keyword.get(opts, :files, ["chelekom.json", "chelekom_headless.json"])

      %{
        "tag_name" => tag,
        "prerelease" => Keyword.get(opts, :prerelease, false),
        "draft" => Keyword.get(opts, :draft, false),
        "assets" =>
          Enum.map(
            files,
            &%{"name" => &1, "browser_download_url" => "https://github.test/#{tag}/#{&1}"}
          )
      }
    end

    # The release list from the API; every kit file downloaded is a bundle named after its URL.
    defp github!(releases) do
      test = self()

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn ->
          case conn.host do
            "api.github.com" ->
              send(test, :looked_up)
              Req.Test.json(conn, releases)

            _download ->
              Req.Test.json(conn, bundle(conn.request_path))
          end
        end
      )
    end

    defp releases do
      [
        release("v3", draft: true),
        release("v2-alpha", prerelease: true),
        release("v1.5", files: []),
        release("v1.4", []),
        release("v1.3", [])
      ]
    end

    test "stable is the newest published release that is not a pre-release and attaches a kit" do
      github!(releases())

      kits = UiKitHandler.official_kits(:stable)

      assert Enum.map(kits, & &1.tag) == ["v1.4", "v1.4"]
      assert Enum.map(kits, & &1.url) == Enum.map(kits, &"https://github.test/v1.4/#{&1.file}")
    end

    test "pre-release is the newest published release of any kind" do
      github!(releases())

      assert Enum.map(UiKitHandler.official_kits(:prerelease), & &1.tag) == [
               "v2-alpha",
               "v2-alpha"
             ]
    end

    # THE CASE TODAY: Chelekom's only releases with kits attached are pre-releases. Installing
    # nothing would be worse than installing the newest one and saying so.
    test "while no stable release attaches a kit, stable takes the newest one and says so", %{
      dir: dir
    } do
      github!([release("v2-alpha", prerelease: true), release("v1", files: [])])

      assert %{release: %{channel: :stable, tag: "v2-alpha", fallback?: true}, failures: []} =
               UiKitHandler.resolve_kits(kits_dir: dir, channel: :stable)
    end

    # NO RELEASE HAS THEM YET: the files committed on master are the last place the kits can be, and
    # the answer says it fell back so the wizard can tell the operator.
    test "while no release attaches a kit at all, every channel takes master and says so", %{
      dir: dir
    } do
      github!([release("v1", files: []), release("v1-alpha", prerelease: true, files: [])])

      for channel <- [:stable, :prerelease] do
        assert %{
                 release: %{channel: :master, tag: "master", fallback?: true},
                 bundles: bundles,
                 failures: []
               } = UiKitHandler.resolve_kits(kits_dir: dir, channel: channel)

        assert Enum.map(bundles, & &1["name"]) ==
                 Enum.map(
                   ["chelekom.json", "chelekom_headless.json"],
                   &"/mishka-group/mishka_chelekom/master/priv/cms_ui_kits/#{&1}"
                 )

        File.rm_rf!(dir)
        File.mkdir_p!(dir)
      end
    end

    # MASTER IS THE LAST PLACE, so a package missing there too is reported, never silently skipped.
    test "a package master does not hold is reported as missing", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn ->
          case conn.host do
            "api.github.com" -> Req.Test.json(conn, [release("v1", files: [])])
            _download -> Plug.Conn.send_resp(conn, 404, "Not Found")
          end
        end
      )

      assert %{
               bundles: [],
               release: %{channel: :master, fallback?: true},
               failures: [%{key: :styled, tag: "master"}, %{key: :headless, tag: "master"}]
             } = UiKitHandler.resolve_kits(kits_dir: dir, channel: :stable)
    end

    test "master is the files committed on master, and asks GitHub's API nothing" do
      github!(releases())

      kits = UiKitHandler.official_kits(:master)

      assert Enum.all?(kits, &(&1.tag == "master"))

      assert Enum.map(kits, & &1.url) ==
               Enum.map(
                 kits,
                 &"https://raw.githubusercontent.com/mishka-group/mishka_chelekom/master/priv/cms_ui_kits/#{&1.file}"
               )

      refute_received :looked_up
    end

    test "a package the release does not attach is reported, not dropped", %{dir: dir} do
      github!([release("v1", files: ["chelekom.json"])])

      assert %{failures: [%{key: :headless, tag: "v1"}], release: %{tag: "v1"}} =
               UiKitHandler.resolve_kits(kits_dir: dir, channel: :stable)
    end

    # THE DEV SEEDS' DOWNLOAD. A kit this server lacks is fetched from the release the installer
    # would pick; a file already there is a developer's own and is never fetched over.
    test "download_missing fetches only the kit that is missing, and keeps the one on disk", %{
      dir: dir
    } do
      place!(dir, "chelekom.json", bundle("from-disk"))
      github!(releases())

      assert UiKitHandler.download_missing(kits_dir: dir) == []

      assert %{"name" => "from-disk"} =
               dir |> Path.join("chelekom.json") |> File.read!() |> Jason.decode!()

      assert %{"name" => "/v1.4/chelekom_headless.json"} =
               dir |> Path.join("chelekom_headless.json") |> File.read!() |> Jason.decode!()
    end

    test "download_missing looks nothing up while every kit is on disk", %{dir: dir} do
      place!(dir, "chelekom.json", bundle("styled"))
      place!(dir, "chelekom_headless.json", bundle("headless"))
      github!(releases())

      assert UiKitHandler.download_missing(kits_dir: dir) == []
      refute_received :looked_up
    end

    test "download_missing names what it could not have", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 403, "rate limited") end
      )

      assert [%{key: :release, reason: "GitHub answered HTTP 403"}] =
               UiKitHandler.download_missing(kits_dir: dir)

      assert File.ls!(dir) == []
    end

    # GITHUB DOWN, OR SIXTY REQUESTS USED UP: say so, and offer what this server already has.
    test "a lookup that fails is named, and the kits on disk are still offered", %{dir: dir} do
      place!(dir, "chelekom.json", bundle("from-disk"))

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 403, "rate limited") end
      )

      assert %{
               bundles: [%{"name" => "from-disk"}],
               failures: [%{key: :release, reason: "GitHub answered HTTP 403"}],
               release: nil
             } = UiKitHandler.resolve_kits(kits_dir: dir, channel: :stable)
    end

    # A developer's bundles win until they pick a version — and nothing is looked up meanwhile.
    test "without a channel, a developer's bundles are used and nothing is looked up", %{dir: dir} do
      place!(dir, "chelekom.json", bundle("from-disk"))
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, true)
      github!(releases())

      assert %{bundles: [%{"name" => "from-disk"}], release: nil} =
               UiKitHandler.resolve_kits(kits_dir: dir)

      refute_received :looked_up
    end

    test "local_only looks nothing up and downloads nothing", %{dir: dir} do
      place!(dir, "chelekom.json", bundle("from-disk"))
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, false)
      github!(releases())

      assert %{bundles: [%{"name" => "from-disk"}], failures: []} =
               UiKitHandler.resolve_kits(kits_dir: dir, local_only: true)

      refute_received :looked_up
    end
  end

  # BOTH SOURCES SUCCEED, so only the precedence can decide which bundle comes back. Asserting on a
  # failing download would prove nothing about ordering — a fallback reaches the file either way.
  defp serve!(name) do
    Application.put_env(:mishka_cms_core, :ui_kit_req_options,
      plug: fn conn ->
        Req.Test.json(conn, %{
          "$schema" => "mishka.ui_kit.bundle.v3",
          "name" => name,
          "components" => []
        })
      end
    )
  end

  describe "precedence between disk and the pinned download" do
    setup %{dir: dir} do
      place!(dir, "precedence.json", bundle("from-disk"))

      Application.put_env(:mishka_cms_core, :official_ui_kits, [
        %{
          key: :styled,
          label: "Styled",
          file: "precedence.json",
          tag: "v1",
          url: "https://example.test/styled.json"
        }
      ])

      serve!("from-network")
      :ok
    end

    # A developer who put a bundle there did so on purpose.
    test "development takes the file a developer placed", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, true)

      assert %{bundles: [%{"name" => "from-disk"}], failures: []} =
               UiKitHandler.resolve_kits(kits_dir: dir)
    end

    # THE POINT OF I2. A stale cache or something baked into an image must not quietly stand in for
    # the version the operator pinned — and before this, it did, because both environments ran the
    # same local-first branch.
    test "production takes the pinned tag even when a file is sitting right there", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, false)

      assert %{bundles: [%{"name" => "from-network"}], failures: []} =
               UiKitHandler.resolve_kits(kits_dir: dir)
    end

    # Fetched once — by the installer, or the first look at the Studio — and read from disk after.
    test "production reads a file that is already the pinned version, without a download", %{
      dir: dir
    } do
      place!(dir, "precedence.json", Map.put(bundle("from-disk"), "version", "1"))
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, false)

      assert %{bundles: [%{"name" => "from-disk"}], failures: []} =
               UiKitHandler.resolve_kits(kits_dir: dir)
    end

    # The download also refreshes the cache, or the next boot would serve the stale file again.
    test "the pinned download replaces what was on disk", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, false)
      UiKitHandler.resolve_kits(kits_dir: dir)

      assert %{"name" => "from-network"} =
               dir |> Path.join("precedence.json") |> File.read!() |> Jason.decode!()
    end
  end

  describe "neither environment dead-ends" do
    setup %{dir: dir} do
      Application.put_env(:mishka_cms_core, :official_ui_kits, [
        %{
          key: :styled,
          label: "Styled",
          file: "fallback.json",
          tag: "v1",
          url: "https://example.test/styled.json"
        }
      ])

      %{dir: dir}
    end

    # A developer who has NOT copied the bundle must still get a working install.
    test "development falls through to the download when no file was placed", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, true)
      serve!("from-network")

      assert %{bundles: [%{"name" => "from-network"}], failures: []} =
               UiKitHandler.resolve_kits(kits_dir: dir)
    end

    # An air-gapped production box has a shipped bundle and no network; it must install from it.
    test "production falls back to the file when the download fails", %{dir: dir} do
      place!(dir, "fallback.json", bundle("from-disk"))
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, false)

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 503, "nope") end
      )

      assert %{bundles: [%{"name" => "from-disk"}], failures: []} =
               UiKitHandler.resolve_kits(kits_dir: dir)
    end

    # THE WIZARD'S BARS. Once a percent while it downloads, ending at the length the server gave.
    test "a download reports how far it has got, ending at its full length", %{dir: dir} do
      body = Jason.encode!(bundle("from-network"))
      size = byte_size(body)
      test = self()

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-length", Integer.to_string(size))
          |> Plug.Conn.send_resp(200, body)
        end
      )

      UiKitHandler.resolve_kits(
        kits_dir: dir,
        progress: fn key, sizes -> send(test, {:progress, key, sizes}) end
      )

      assert_received {:progress, :styled, {^size, ^size}}
    end

    test "a package read from disk reports no download", %{dir: dir} do
      place!(dir, "fallback.json", bundle("from-disk"))
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, true)
      test = self()

      UiKitHandler.resolve_kits(
        kits_dir: dir,
        progress: fn key, sizes -> send(test, {:progress, key, sizes}) end
      )

      refute_received {:progress, _key, _sizes}
    end

    # And when BOTH are gone, the reason reported is the network one — "not on disk" is never news.
    test "a package with no source reports why the download failed", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :prefer_local_ui_kits, true)

      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 404, "") end
      )

      assert %{bundles: [], failures: [%{reason: "HTTP 404"}]} =
               UiKitHandler.resolve_kits(kits_dir: dir)
    end
  end

  describe "adding a package by URL" do
    setup %{dir: dir} do
      Application.put_env(:mishka_cms_core, :official_ui_kits, [])
      %{dir: dir}
    end

    defp serve_body!(status, body) do
      Application.put_env(:mishka_cms_core, :ui_kit_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, status, body) end
      )
    end

    test "a valid bundle is cached beside the official ones and joins the catalogue", %{dir: dir} do
      serve_body!(200, Jason.encode!(bundle("acme")))

      assert {:ok, %{"name" => "acme"}} =
               UiKitHandler.add_custom_kit("https://example.test/acme.json", kits_dir: dir)

      # The SAME path an official kit takes: on disk, so it is discovered on the next boot too.
      assert %{bundles: [%{"name" => "acme"}]} = UiKitHandler.resolve_kits(kits_dir: dir)
    end

    # Where a kit came from matters more for one of these than for a package we shipped.
    test "the source URL is recorded on the cached bundle", %{dir: dir} do
      serve_body!(200, Jason.encode!(bundle("acme")))
      UiKitHandler.add_custom_kit("https://example.test/acme.json", kits_dir: dir)

      assert %{"source_url" => "https://example.test/acme.json"} =
               dir |> Path.join("acme.json") |> File.read!() |> Jason.decode!()
    end

    # A 200 that is really an HTML error page must not install as an empty kit.
    test "a response that is not a v3 bundle is refused", %{dir: dir} do
      serve_body!(200, "<html><body>Not found</body></html>")

      assert {:error, reason} =
               UiKitHandler.add_custom_kit("https://example.test/nope.json", kits_dir: dir)

      assert reason =~ "not valid JSON"
      assert File.ls!(dir) == [], "nothing may be written when a check fails"
    end

    test "valid JSON that is not a bundle is refused by schema", %{dir: dir} do
      serve_body!(200, Jason.encode!(%{"hello" => "world"}))

      assert {:error, reason} =
               UiKitHandler.add_custom_kit("https://example.test/x.json", kits_dir: dir)

      assert reason =~ "mishka.ui_kit.bundle.v3"
      assert File.ls!(dir) == []
    end

    # PREFIX COLLISION IS DATA LOSS: `uninstall_kit!/2` purges components by prefix, so two kits
    # sharing a name means removing one deletes the other's rows.
    test "a name already installed is refused", %{dir: dir} do
      place!(dir, "acme.json", bundle("acme"))
      serve_body!(200, Jason.encode!(bundle("acme")))

      assert {:error, reason} =
               UiKitHandler.add_custom_kit("https://example.test/acme.json", kits_dir: dir)

      assert reason =~ "already installed"
    end

    # An unbounded read of a URL a stranger controls is the whole risk.
    test "a response past the size limit is abandoned mid-read", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :max_ui_kit_bytes, 64)
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :max_ui_kit_bytes) end)

      serve_body!(200, Jason.encode!(bundle("acme", List.duplicate(%{"name" => "x"}, 200))))

      assert {:error, reason} =
               UiKitHandler.add_custom_kit("https://example.test/big.json", kits_dir: dir)

      assert reason =~ "larger than"
      assert File.ls!(dir) == []
    end

    test "a non-http address never reaches the network", %{dir: dir} do
      serve_body!(200, Jason.encode!(bundle("acme")))

      for bad <- ["ftp://example.test/a.json", "example.test/a.json", "", "   "] do
        assert {:error, _reason} = UiKitHandler.add_custom_kit(bad, kits_dir: dir)
      end

      assert File.ls!(dir) == []
    end

    test "a transport failure is reported, not raised", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :ui_kit_req_options, [])

      assert {:error, reason} =
               UiKitHandler.add_custom_kit("https://127.0.0.1:1/a.json", kits_dir: dir)

      assert is_binary(reason)
    end
  end

  describe "a kit declaring its precompilation tier" do
    # `Page`, `Layout` and `ErrorPage` all carry `:precompile`; `Component` did not, so every
    # installed component was compiled at boot — 251 modules in the VM for a site that renders a
    # handful. `precompile` says build the module at boot rather than on first render, `required`
    # says the installer may not deselect the component; neither decides CSS, which is per site and
    # computed from what that site reaches. Both are worth nothing unless they survive the trip
    # from JSON to the row.
    test "the accepted inputs carry both flags" do
      accepted =
        for action <- Ash.Resource.Info.actions(MishkaCmsCore.Runtime.Component),
            action.name in [:master_create, :master_update],
            field <- action.accept || [],
            into: MapSet.new(),
            do: field

      assert MapSet.member?(accepted, :precompile),
             "the installer filters params by what the actions accept, so an unaccepted flag is dropped in silence"

      assert MapSet.member?(accepted, :required)
    end

    test "both default to false, so a bundle written before they existed is unaffected" do
      assert Ash.Resource.Info.attribute(MishkaCmsCore.Runtime.Component, :precompile).default ==
               false

      assert Ash.Resource.Info.attribute(MishkaCmsCore.Runtime.Component, :required).default ==
               false
    end
  end

  describe "who may install where" do
    # A MASTER has no site of their own, which is exactly what lets them install for every site.
    test "a master may install globally or into any one site" do
      master = %{site_id: nil}

      assert {:ok, nil} = UiKitHandler.install_scope(master, :global)
      assert {:ok, nil} = UiKitHandler.install_scope(master, nil)
      assert {:ok, "acme"} = UiKitHandler.install_scope(master, "acme")
      assert {:ok, "other"} = UiKitHandler.install_scope(master, "other")
    end

    # Omitting the field is not an attack — a form that does not carry a scope means "mine".
    test "a tenant asking for nothing gets their own site" do
      assert {:ok, "acme"} = UiKitHandler.install_scope(%{site_id: "acme"}, nil)
      assert {:ok, "acme"} = UiKitHandler.install_scope(%{site_id: "acme"}, "acme")
    end

    # THE ONE THAT MATTERS. The scope arrives on an event, and an event is whatever the client sent;
    # a tenant who never sees the control can still emit the click with `scope: "global"`, and
    # `install_kit!/2` writes `site_id` straight through. Their components would land on every site
    # on the server, removable only by a master.
    test "a tenant cannot reach another site, or every site" do
      tenant = %{site_id: "acme"}

      assert {:error, :forbidden} = UiKitHandler.install_scope(tenant, "other")

      # THE ONE THE FIRST VERSION LET THROUGH. "global" was encoded as `nil`, which also meant
      # "unspecified", so a tenant asking for every site matched the "give them their own" clause.
      assert {:error, :forbidden} = UiKitHandler.install_scope(tenant, :global)
    end

    test "an unauthenticated caller installs nothing" do
      assert {:error, :forbidden} = UiKitHandler.install_scope(nil, nil)
      assert {:error, :forbidden} = UiKitHandler.install_scope(%{}, "acme")
    end
  end

  describe "resolving" do
    test "a kit already on disk is used without touching the network", %{dir: dir} do
      place!(dir, "sources_test_styled.json", bundle("sources-test-styled"))

      Application.put_env(:mishka_cms_core, :official_ui_kits, [
        %{
          key: :styled,
          label: "Styled",
          file: "sources_test_styled.json",
          tag: "v1",
          # Unroutable on purpose: reaching for it at all is the failure this asserts against.
          url: "https://127.0.0.1:1/never.json"
        }
      ])

      assert %{bundles: [%{"name" => "sources-test-styled"}], failures: []} =
               UiKitHandler.resolve_kits(kits_dir: dir)
    end

    # THE REASON `resolve_kits/1` EXISTS. With two official packages, one 404 used to raise out of
    # `ensure_bundles!/1` and take the other — and every third-party bundle on disk — with it.
    test "one package failing leaves the others installable", %{dir: dir} do
      place!(dir, "sources_test_ok.json", bundle("sources-test-ok"))

      Application.put_env(:mishka_cms_core, :official_ui_kits, [
        %{
          key: :ok,
          label: "Reachable",
          file: "sources_test_ok.json",
          tag: "v1",
          url: "https://127.0.0.1:1/a.json"
        },
        %{
          key: :gone,
          label: "Missing",
          file: "sources_test_gone.json",
          tag: "v1",
          url: "https://127.0.0.1:1/b.json"
        }
      ])

      assert %{bundles: [%{"name" => "sources-test-ok"}], failures: [failure]} =
               UiKitHandler.resolve_kits(kits_dir: dir)

      assert failure.key == :gone
      assert failure.label == "Missing"
      assert failure.tag == "v1"
      assert is_binary(failure.reason) and failure.reason != ""
    end

    test "a bundle on disk that is not official still joins", %{dir: dir} do
      place!(dir, "sources_test_third_party.json", bundle("sources-test-third-party"))
      Application.put_env(:mishka_cms_core, :official_ui_kits, [])

      names = UiKitHandler.resolve_kits(kits_dir: dir).bundles |> Enum.map(& &1["name"])

      assert "sources-test-third-party" in names
    end

    # Silence would be worse than the raise it replaced: an installer showing an empty picker with no
    # message is indistinguishable from a kit with no components.
    test "ensure_bundles!/1 raises only when nothing at all resolves", %{dir: dir} do
      Application.put_env(:mishka_cms_core, :official_ui_kits, [
        %{
          key: :gone,
          label: "Missing",
          file: "sources_test_absent.json",
          tag: "v2",
          url: "https://127.0.0.1:1/x.json"
        }
      ])

      assert %{bundles: []} = UiKitHandler.resolve_kits(kits_dir: dir)

      assert_raise RuntimeError, ~r/no UI-kit bundle could be resolved/, fn ->
        UiKitHandler.ensure_bundles!(kits_dir: dir)
      end
    end
  end
end
