defmodule MishkaCmsCore.UiKit.MultiKitTest do
  @moduledoc """
  More than one UI kit.

  The CMS ships Chelekom, and the same generator already exports a second bundle from its headless
  set (`mix mishka.ui.export priv/headless --cms --name chelekom_headless`). Nothing about the
  install path was ever Chelekom-specific except where it looked for the file, so this pins the two
  properties that make a second kit possible: the installer finds bundles by looking in the
  directory, and two kits installed side by side do not delete each other.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Install.UiKitCatalog
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  require Ash.Query

  defp bundle(name, components) do
    %{
      "$schema" => "mishka.ui_kit.bundle.v3",
      "name" => name,
      "version" => "0.0.1",
      "components" => components,
      "js_hooks" => [],
      "stylesheets" => []
    }
  end

  defp component(name, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "type" => "general",
        "format" => "heex",
        "template" => "<div>#{name}</div>",
        "body" => nil,
        "attrs" => [],
        "slots" => [],
        "helpers" => [],
        "examples" => [],
        "extra" => %{},
        "dependencies" => [],
        "permissions" => [],
        "priority" => 0,
        "active" => true,
        "site_id" => nil
      },
      overrides
    )
  end

  defp write_bundle!(dir, file, bundle) do
    path = Path.join(dir, file)
    File.write!(path, Jason.encode!(bundle))
    path
  end

  describe "kits_dir/0" do
    test "is the configured :ui_kits_dir, and every default reads and writes there" do
      dir = Path.join(System.tmp_dir!(), "kits_dir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      write_bundle!(dir, "acme.json", bundle("acme", [component("acme-card")]))
      Application.put_env(:mishka_cms_core, :ui_kits_dir, dir)

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :ui_kits_dir)
        File.rm_rf(dir)
      end)

      assert UiKitHandler.kits_dir() == dir
      assert UiKitHandler.default_bundle_path() == Path.join(dir, "chelekom.json")
      assert UiKitHandler.bundle_files() == [Path.join(dir, "acme.json")]
      assert [%{name: "acme", components: 1}] = UiKitHandler.available_kits()
    end

    test "is priv/cms_ui_kits when nothing is configured" do
      assert UiKitHandler.kits_dir() ==
               Path.join([:code.priv_dir(:mishka_cms_core), "cms_ui_kits"])
    end
  end

  describe "available_kits/0" do
    test "reports every readable bundle in the kits directory" do
      kits = UiKitHandler.available_kits()

      assert Enum.any?(kits, &(&1.name == "chelekom"))

      chelekom = Enum.find(kits, &(&1.name == "chelekom"))
      assert chelekom.components > 100
      assert is_binary(chelekom.version)
      assert String.ends_with?(chelekom.path, "chelekom.json")
    end

    # An installer that refuses to start because somebody left a note in the kits directory is worse
    # than one that ignores it.
    test "a file that is not a bundle is skipped, not raised on" do
      dir = Path.dirname(UiKitHandler.default_bundle_path())
      stray = Path.join(dir, "not-a-bundle-#{System.unique_integer([:positive])}.json")
      File.write!(stray, "{ this is not json")

      on_exit(fn -> File.rm(stray) end)

      assert Enum.any?(UiKitHandler.available_kits(), &(&1.name == "chelekom"))
    end
  end

  describe "bundle_files/1" do
    test "lists every .json file by path, sorted, whether or not it is a bundle" do
      dir = Path.join(System.tmp_dir!(), "kit-files-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      write_bundle!(dir, "b.json", bundle("b", [component("b-alert")]))
      File.write!(Path.join(dir, "a.json"), "{ this is not json")
      File.write!(Path.join(dir, "notes.txt"), "not a kit")

      assert UiKitHandler.bundle_files(dir) == [
               Path.join(dir, "a.json"),
               Path.join(dir, "b.json")
             ]

      assert Enum.map(UiKitHandler.available_kits(dir), & &1.name) == ["b"]
    end
  end

  describe "two kits side by side" do
    setup do
      dir = Path.dirname(UiKitHandler.default_bundle_path())
      suffix = System.unique_integer([:positive])
      styled = "kitstyled#{suffix}"
      headless = "kitheadless#{suffix}"

      styled_path =
        write_bundle!(dir, "#{styled}.json", bundle(styled, [component("#{styled}-alert")]))

      headless_path =
        write_bundle!(dir, "#{headless}.json", bundle(headless, [component("#{headless}-tree")]))

      on_exit(fn ->
        File.rm(styled_path)
        File.rm(headless_path)
      end)

      %{
        styled: styled,
        headless: headless,
        styled_path: styled_path,
        headless_path: headless_path
      }
    end

    test "both are discovered", %{styled: styled, headless: headless} do
      names = Enum.map(UiKitHandler.available_kits(), & &1.name)

      assert styled in names
      assert headless in names
    end

    test "installing one leaves the other's components alone", %{
      styled: styled,
      headless: headless,
      styled_path: styled_path,
      headless_path: headless_path
    } do
      UiKitHandler.install_kit!(styled_path, site_id: nil)
      UiKitHandler.install_kit!(headless_path, site_id: nil, cleanup: true)

      names = installed_names()

      assert "#{styled}-alert" in names
      assert "#{headless}-tree" in names
    end

    test "install_kits!/2 installs only the kits named", %{
      styled: styled,
      headless: headless
    } do
      UiKitHandler.install_kits!([headless], site_id: nil)

      names = installed_names()

      assert "#{headless}-tree" in names
      refute "#{styled}-alert" in names
    end

    test "a per-kit selection reaches only that kit", %{styled: styled, headless: headless} do
      UiKitHandler.install_kits!([styled, headless],
        site_id: nil,
        selection: %{styled => %{components: ["alert"]}, headless => %{components: []}}
      )

      names = installed_names()

      assert "#{styled}-alert" in names
      refute "#{headless}-tree" in names
    end
  end

  describe "UiKitCatalog" do
    # The kit's own name is the prefix. Taking it from a constant is what would stop a second kit
    # from ever showing readable labels in the picker.
    test "labels a component by stripping whichever kit shipped it" do
      assert UiKitCatalog.label("chelekom-alert") == "alert"
      # `Component` slugifies what it stores, so a bundle named `chelekom_headless` installs
      # `chelekom-headless-tree`. Given the kit, the whole prefix comes off.
      assert UiKitCatalog.label("chelekom-headless-tree", "chelekom_headless") == "tree"
      assert UiKitCatalog.label("chelekom-alert", "chelekom") == "alert"
      assert UiKitCatalog.label("noprefix") == "noprefix"
    end

    test "builds a picker over any bundle, not only Chelekom" do
      catalog =
        UiKitCatalog.build(bundle("acme", [component("acme-widget"), component("acme-panel")]))

      labels =
        catalog.groups
        |> Enum.flat_map(& &1.entries)
        |> Enum.map(& &1.label)
        |> Enum.sort()

      assert labels == ["panel", "widget"]
    end
  end

  describe "one catalogue over two kits" do
    setup do
      styled = bundle("acme", [component("acme-alert"), component("acme-card")])
      headless = bundle("acme_headless", [component("acme-headless-tree")])

      %{catalog: UiKitCatalog.merge([styled, headless])}
    end

    test "every kit's components are offered, labelled by their own kit", %{catalog: catalog} do
      labels =
        catalog.groups |> Enum.flat_map(& &1.entries) |> Enum.map(& &1.label) |> Enum.sort()

      assert labels == ["alert", "card", "tree"]
    end

    test "an entry remembers which kit shipped it", %{catalog: catalog} do
      kits = catalog.index |> Map.values() |> Enum.map(& &1.kit) |> Enum.uniq() |> Enum.sort()

      assert kits == ["acme", "acme_headless"]
    end

    # The labels a selection is keyed by are unique per kit but not across kits, so a flat map would
    # install one kit's narrowing onto another kit's component of the same name.
    test "the install selection is split per kit", %{catalog: catalog} do
      selection =
        UiKitCatalog.install_selection_by_kit(
          catalog,
          MapSet.new(["acme-alert", "acme-headless-tree"]),
          %{}
        )

      assert Map.keys(selection) |> Enum.sort() == ["acme", "acme_headless"]
      assert selection["acme"].components == ["acme-alert"]
      assert selection["acme_headless"].components == ["acme-headless-tree"]
      assert Map.has_key?(selection["acme_headless"].per_component, "tree")
    end

    # The installer draws a chip per kit and a badge per component. Both need the kit's own name in
    # a form a person reads, and `chelekom_headless` is not it.
    # The contract runs at the LOAD boundary, so a malformed component never reaches the install at
    # all — and the rest of the kit installs regardless.
    test "a component that fails the contract is skipped, and the rest of the kit installs" do
      kit =
        bundle("acme", [
          component("acme-alert"),
          component("acme-broken") |> Map.delete("template"),
          component("acme-card")
        ])

      path = Path.join(System.tmp_dir!(), "acme_contract.json")
      File.write!(path, Jason.encode!(kit))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{components: installed}} = UiKitHandler.install_kit!(path, site_id: nil)

      assert length(installed) == 2
      assert installed?("acme-alert")
      assert installed?("acme-card")
      refute installed?("acme-broken")
    end

    # `Component` slugifies what it stores, so `acme_headless` installs `acme-headless-tree`. The
    # uninstall matched on the RAW name, which meant any kit with an underscore could be installed
    # and then never removed.
    test "a kit whose name has an underscore can be uninstalled again" do
      kit = bundle("acme_headless", [component("acme-headless-tree")])
      path = Path.join(System.tmp_dir!(), "acme_headless_uninstall.json")
      File.write!(path, Jason.encode!(kit))
      on_exit(fn -> File.rm(path) end)

      {:ok, _installed} = UiKitHandler.install_kit!(path, site_id: nil)
      assert installed?("acme-headless-tree")

      :ok = UiKitHandler.uninstall_kit!(path, site_id: nil)
      refute installed?("acme-headless-tree")
    end

    # A bundle is somebody else's file. One key this CMS's resource does not accept used to raise
    # `Ash.Error.Invalid` out of the install — which, from the Studio's Install button, took the
    # editor's LiveView down with it.
    test "a key the resource does not accept is dropped, not raised on" do
      kit =
        bundle("acme", [
          component("acme-alert") |> Map.put("args", ["a", "b"]) |> Map.put("nonesuch", 1)
        ])

      path = Path.join(System.tmp_dir!(), "acme_extra_keys.json")
      File.write!(path, Jason.encode!(kit))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{components: [_installed]}} = UiKitHandler.install_kit!(path, site_id: nil)

      assert MishkaCmsCore.Runtime.Component
             |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
             |> Ash.Query.filter(name == "acme-alert")
             |> Ash.read!(page: [limit: 5])
             |> Map.fetch!(:results)
             |> length() == 1
    end

    test "a kit names itself readably for the picker's chips", %{catalog: catalog} do
      kits = catalog.index |> Map.values() |> Enum.map(& &1.kit) |> Enum.uniq() |> Enum.sort()

      assert Enum.map(kits, &UiKitCatalog.kit_label/1) == ["Acme", "Acme Headless"]
      assert UiKitCatalog.kit_label(nil) == ""
    end

    test "selecting from one kit leaves the other out of the selection entirely", %{
      catalog: catalog
    } do
      selection = UiKitCatalog.install_selection_by_kit(catalog, MapSet.new(["acme-card"]), %{})

      assert Map.keys(selection) == ["acme"]
    end
  end

  defp installed?(name) do
    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^name)
    |> Ash.read!(page: [limit: 5])
    |> Map.fetch!(:results)
    |> Enum.any?()
  end

  describe "bootstrap" do
    # The installer's own selection shape. A flat one is what a single-kit install produced before
    # more than one kit existed and must keep working; a per-kit one installs each named kit.
    test "a per-kit selection installs every kit it names", %{} do
      dir = Path.dirname(UiKitHandler.default_bundle_path())
      suffix = System.unique_integer([:positive])
      one = "bootone#{suffix}"
      two = "boottwo#{suffix}"

      one_path = write_bundle!(dir, "#{one}.json", bundle(one, [component("#{one}-alpha")]))
      two_path = write_bundle!(dir, "#{two}.json", bundle(two, [component("#{two}-beta")]))

      on_exit(fn ->
        File.rm(one_path)
        File.rm(two_path)
      end)

      UiKitHandler.install_kits!([one, two],
        site_id: nil,
        selection: %{
          one => %{components: ["#{one}-alpha"]},
          two => %{components: ["#{two}-beta"]}
        }
      )

      names = installed_names()

      assert "#{one}-alpha" in names
      assert "#{two}-beta" in names
    end
  end

  defp installed_names do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.read!(page: [limit: 500])
    |> Map.fetch!(:results)
    |> Enum.map(& &1.name)
  end
end
