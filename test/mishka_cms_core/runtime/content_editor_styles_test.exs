defmodule MishkaCmsCore.Runtime.ContentEditorStylesTest do
  @moduledoc """
  The stylesheet the content editor draws its previews with (`ContentEditorStyles`): built with the
  real Tailwind binary from the site and the components named, kept until what it is built from
  changes, and holding a component's own classes — every variant its template spells out — before
  any saved content uses it.

  Who may fetch it is the host's `MishkaCmsWeb.SiteBundleTest`.

  `async: false` — `SiteState`, `AssetsState` and the runtime template directory are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.ContentEditorStyles
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}

  @moduletag :integration

  setup do
    n = System.unique_integer([:positive])

    site = %{
      id: Ecto.UUID.generate(),
      name: "editor-styles-#{n}",
      host: "editor-styles-#{n}.test"
    }

    :ok = SiteState.save(Map.merge(site, %{priority: 0, active: true}))

    # Where the compile worker writes a site's component templates for Tailwind to read.
    dir = Path.join([:code.priv_dir(:mishka_cms_core), "static", "temp", "runtime", site.name])
    File.mkdir_p!(Path.join(dir, "component"))

    File.write!(
      Path.join([dir, "component", "probe-#{n}.template"]),
      ~S|<div class={["bg-[#a1b2c3]", @variant == "shadow" && "shadow-[0_2px_3px_#b1c2d3]"]}></div>|
    )

    on_exit(fn ->
      SiteState.delete(site.id)
      AssetsState.delete(ContentEditorStyles.key(site.id), "css")
      File.rm_rf(dir)
    end)

    {:ok, site: site, probe: "probe-#{n}"}
  end

  test "holds the classes of the components named, every variant of them", ctx do
    assert {:ok, href} = ContentEditorStyles.ensure(ctx.site.id, [ctx.probe])

    key = ContentEditorStyles.key(ctx.site.id)
    %{hash: hash, value: css} = AssetsState.get!(key, "css")

    assert href == "/assets/css/#{key}/#{hash}"
    assert css =~ "a1b2c3"
    assert css =~ "b1c2d3"
    refute css =~ ~r/:root\{/
  end

  test "is built once, and again only when what it is built from changes", ctx do
    {:ok, href} = ContentEditorStyles.ensure(ctx.site.id, [ctx.probe, "chelekom-badge"])
    built = AssetsState.updated_at(ContentEditorStyles.key(ctx.site.id), "css")

    assert ContentEditorStyles.ensure(ctx.site.id, ["chelekom-badge", ctx.probe]) == {:ok, href}
    assert AssetsState.updated_at(ContentEditorStyles.key(ctx.site.id), "css") == built

    assert {:ok, other} = ContentEditorStyles.ensure(ctx.site.id, [ctx.probe])
    refute other == href
  end

  test "names nothing it could not write into a template", ctx do
    assert {:ok, _href} = ContentEditorStyles.ensure(ctx.site.id, [~s(x" onload="y), ctx.probe])
    refute AssetsState.get_value(ContentEditorStyles.key(ctx.site.id), "css") =~ "onload"
  end

  test "is no stylesheet for a site nobody knows" do
    assert ContentEditorStyles.ensure(Ecto.UUID.generate(), []) == {:error, :unknown_site}
  end

  test "site_of/1 reads back only the ids key/1 makes" do
    id = Ecto.UUID.generate()

    assert ContentEditorStyles.site_of(ContentEditorStyles.key(id)) == {:ok, id}
    assert ContentEditorStyles.site_of("localhost") == :error
  end
end
