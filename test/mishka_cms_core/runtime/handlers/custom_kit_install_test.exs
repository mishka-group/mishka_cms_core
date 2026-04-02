defmodule MishkaCmsCore.Runtime.Handlers.CustomKitInstallTest do
  @moduledoc """
  A package an operator pasted a URL for, from download to rows in the database.

  `ui_kit_sources_test.exs` covers the download half — bad shapes, size ceilings, name collisions,
  the recorded source URL. What nothing covered was the other half: that a kit which is not
  Chelekom, fetched over HTTP, actually INSTALLS and produces the right rows. That is the path an
  operator takes when they bring their own package, and it is the one the whole kit-agnostic effort
  exists to serve.

  The bundle here is deliberately foreign in every way that used to be assumed:

    * its categories are `widgets` and `charts`, which no colour table has heard of;
    * its axis is `tone`, which is not one of the seven names the installer used to recognise;
    * its helper takes COLOUR first and tone second, the opposite of Chelekom's order;
    * it declares its own `required` and `precompile`;
    * and it ships two rows that are wrong on purpose — a hook with no body and a stylesheet whose
      `kind` is a word this CMS does not have.

  Those last two are the point of A1: one bad row costs that row, not the other 136.

  `async: false` — installs write global runtime rows and the handler reads app env.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.JsHook
  alias MishkaCmsCore.Runtime.Stylesheet

  @url "https://example.test/acmekit.json"

  setup do
    dir = Path.join(System.tmp_dir!(), "custom_kit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    official = Application.fetch_env!(:mishka_cms_core, :official_ui_kits)
    Application.put_env(:mishka_cms_core, :official_ui_kits, [])

    Application.put_env(:mishka_cms_core, :ui_kit_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 200, Jason.encode!(bundle())) end
    )

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :ui_kit_req_options)
      Application.put_env(:mishka_cms_core, :official_ui_kits, official)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp clause(color, tone) do
    %{
      "name" => "paint",
      "args" => ~s|"#{color}", "#{tone}"|,
      "code" => ~s|defp paint("#{color}", "#{tone}"), do: "#{color}-#{tone}"|
    }
  end

  defp bundle do
    %{
      "$schema" => "mishka.ui_kit.bundle.v3",
      "name" => "acmekit",
      "version" => "1.2.0",
      "components" => [
        %{
          "name" => "acme-icon",
          "type" => "widgets",
          "template" => ~s|<span class={[@name, @class]} />|,
          "required" => true,
          "precompile" => true
        },
        %{
          "name" => "acme-chip",
          "type" => "widgets",
          "template" => ~s|<span class={paint(@color, @tone)}>x</span>|,
          "dependencies" => ["acme-icon"],
          "attrs" => [
            %{
              "name" => "color",
              "type" => "string",
              "opts" => %{"values" => ["brand", "danger"], "default" => "brand"}
            },
            %{
              "name" => "tone",
              "type" => "string",
              "opts" => %{"values" => ["calm", "loud"], "default" => "calm"}
            }
          ],
          "helpers" => [
            clause("brand", "calm"),
            clause("brand", "loud"),
            clause("danger", "calm"),
            clause("danger", "loud")
          ]
        },
        %{"name" => "acme-gauge", "type" => "charts", "template" => ~s|<div class="h-2">g</div>|}
      ],
      "js_hooks" => [
        %{"name" => "AcmeEmpty"},
        %{"name" => "AcmeGood", "content" => "export default {mounted(){}}"}
      ],
      "stylesheets" => [%{"name" => "acme-theme", "content" => "@theme {}", "kind" => "tokens"}]
    }
  end

  defp add_and_install!(dir) do
    assert {:ok, %{"name" => "acmekit"}} = UiKitHandler.add_custom_kit(@url, kits_dir: dir)

    path = Path.join(dir, "acmekit.json")
    UiKitHandler.install_kit!(path, site_id: nil)
    on_exit(fn -> UiKitHandler.uninstall_kit!(path, kit_name: "acmekit") end)

    path
  end

  defp rows(resource, names) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name in ^names)
    |> Ash.read!(page: [limit: 50])
    |> Map.fetch!(:results)
  end

  describe "a third-party package fetched from a URL" do
    test "installs every component it ships", %{dir: dir} do
      add_and_install!(dir)

      installed = rows(Component, ["acme-icon", "acme-chip", "acme-gauge"])

      assert length(installed) == 3
    end

    # The categories are the kit's own words. Rewriting them to something recognised would be the
    # same mistake the palette's colour table made.
    test "keeps a taxonomy the CMS has never heard of", %{dir: dir} do
      add_and_install!(dir)

      types = rows(Component, ["acme-icon", "acme-gauge"]) |> Map.new(&{&1.name, &1.type})

      assert types["acme-icon"] == "widgets"
      assert types["acme-gauge"] == "charts"
    end

    test "carries the kit's own required and precompile flags", %{dir: dir} do
      add_and_install!(dir)

      [icon] = rows(Component, ["acme-icon"])
      [gauge] = rows(Component, ["acme-gauge"])

      assert icon.required and icon.precompile
      refute gauge.required or gauge.precompile
    end

    # Nothing was selected, so nothing is narrowed and every clause survives — a component that
    # renders at any combination the Inspector can offer.
    test "keeps every helper clause when no axis was chosen for", %{dir: dir} do
      add_and_install!(dir)

      [chip] = rows(Component, ["acme-chip"])

      assert length(chip.helpers) == 4
    end

    # A1: the bad rows cost themselves and nothing else.
    test "skips a body-less hook and still installs the good one", %{dir: dir} do
      add_and_install!(dir)

      assert rows(JsHook, ["acmegood"]) != []
      assert rows(JsHook, ["acmeempty"]) == []
    end

    test "coerces a stylesheet kind the CMS does not have rather than aborting", %{dir: dir} do
      add_and_install!(dir)

      assert [sheet] = rows(Stylesheet, ["acme-theme"])
      assert sheet.kind in [:app_base, :theme, :base, :custom]

      assert rows(Component, ["acme-icon"]) != [],
             "a bad stylesheet used to cost every component in the bundle"
    end

    # THE OTHER HALF OF INSTALL. Uninstall selected rows by the kit's name used as a PREFIX, which is
    # only true of a kit that names its components after itself — Chelekom's `chelekom` /
    # `chelekom-*`. This bundle is called `acmekit` and ships `acme-*`, so uninstall returned `:ok`,
    # removed the hooks and the stylesheet, and left every component installed forever with no
    # surface anywhere to remove them.
    test "uninstalls the components it installed, whatever they are named", %{dir: dir} do
      assert {:ok, _bundle} = UiKitHandler.add_custom_kit(@url, kits_dir: dir)
      path = Path.join(dir, "acmekit.json")
      UiKitHandler.install_kit!(path, site_id: nil)

      assert length(rows(Component, ["acme-icon", "acme-chip", "acme-gauge"])) == 3

      assert :ok = UiKitHandler.uninstall_kit!(path, kit_name: "acmekit")

      assert rows(Component, ["acme-icon", "acme-chip", "acme-gauge"]) == [],
             "the kit's own name is not a prefix of its components, and that used to be fatal"
    end

    # Provenance is what makes the above possible, and it is written at INSTALL from the installing
    # bundle's name — a hand-written bundle need not stamp itself the way Chelekom's exporter does.
    test "stamps every row with the kit it came from", %{dir: dir} do
      add_and_install!(dir)

      kits =
        rows(Component, ["acme-icon", "acme-chip", "acme-gauge"])
        |> Enum.map(&get_in(&1.extra, ["ui_kit"]))

      assert kits == ["acmekit", "acmekit", "acmekit"]
    end

    test "records where the package came from", %{dir: dir} do
      path = add_and_install!(dir)

      assert %{"source_url" => @url} = path |> File.read!() |> Jason.decode!()
    end
  end
end
