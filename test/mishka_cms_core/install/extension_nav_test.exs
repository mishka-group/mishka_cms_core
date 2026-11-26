# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.ExtensionNavTest do
  @moduledoc """
  An extension's `nav` (`MishkaCmsCore.Install.Extensions`) reaches a site's header menu when the
  extension is first set up there (`MishkaCmsCore.Install.StarterContent.add_nav_link/2`): once,
  never beside a link the header already has in any form, and never again on a later run, so a
  link the owner removed stays removed. The dev sites' `Dev` dropdown lists the same links.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Install.{Extensions, Seeds, StarterContent}
  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Test.Installer
  alias MishkaCmsCore.Test.Plugins.{ExtensionNavProbe, SeedProbe}

  require Ash.Query

  @key "mishka_nav_probe"
  @nav [%{label: "Blog", path: "/blog"}, %{label: "Store", to: "/store"}]

  setup do
    dir = Path.join(System.tmp_dir!(), "nav_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    Installer.register!(ExtensionNavProbe, Extensions.event(), %{
      extension: :mishka_nav_probe,
      priority: 50,
      extra: [%{label: "Nav probe", summary: "", fields: [], nav: @nav}]
    })

    name = "nav#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true, master: true)
    StarterContent.seed!(site)
    %{site: site}
  end

  defp template(site) do
    Layout
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and name == "site-main")
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:template)
  end

  defp edit_template!(site, fun) do
    Layout
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and name == "site-main")
    |> Ash.read_one!(authorize?: false)
    |> Ash.Changeset.for_update(:update, %{template: fun.(template(site))},
      tenant: site.id,
      authorize?: false,
      context: %{page_code: :package}
    )
    |> Ash.update!()
  end

  defp count(text, part), do: length(String.split(text, part)) - 1

  @blog ~s|site_path("/:lang/blog"|
  @store ~s|navigate="/store"|

  test "the extension declares its links once, for the install and the Dev dropdown" do
    assert %{nav: @nav} = Enum.find(Extensions.installable(), &(&1.key == @key))

    Installer.register!(SeedProbe, Seeds.event(), %{
      extension: :mishka_nav_probe,
      priority: 50,
      extra: [%{id: "pages", label: "Pages", envs: [:dev, :prod], default: true}]
    })

    assert Seeds.nav() == @nav
  end

  test "a first install adds its links to the header once, and a second run adds nothing", %{
    site: site
  } do
    refute template(site) =~ @blog

    assert {:ok, _report} = Extensions.install(site.id, @key)
    header = template(site)
    assert count(header, @blog) == 1
    assert count(header, @store) == 1
    assert header =~ ">Blog</.link>"
    assert header =~ ">Store</.link>"

    assert {:ok, _report} = Extensions.install(site.id, @key)
    assert template(site) == header
  end

  test "a header that already links the path in any form is left as it is", %{site: site} do
    edit_template!(site, fn template ->
      String.replace(
        template,
        "</.component>",
        ~s|<.link navigate="/en/blog/">Our blog</.link>\n      </.component>|,
        global: false
      )
    end)

    assert {:ok, _report} = Extensions.install(site.id, @key)
    header = template(site)
    refute header =~ @blog
    assert count(header, "/blog") == 1
    assert count(header, @store) == 1
  end

  test "a link the owner removed after the install is not put back by a later run", %{
    site: site
  } do
    assert {:ok, _report} = Extensions.install(site.id, @key)
    edit_template!(site, &String.replace(&1, ~r|\n\s*<\.link navigate="/store"[^\n]*|, ""))
    refute template(site) =~ @store

    assert {:ok, _report} = Extensions.install(site.id, @key)
    refute template(site) =~ @store
    assert count(template(site), @blog) == 1
  end

  test "add_nav_link/2 says what it did", %{site: site} do
    assert StarterContent.add_nav_link(site.id, %{label: "Docs", path: "/docs"}) == :added
    assert StarterContent.add_nav_link(site.id, %{label: "Docs", to: "/docs"}) == :held

    other = create_site!(name: "bare#{System.unique_integer([:positive])}", active: true)
    assert StarterContent.add_nav_link(other.id, %{label: "Docs", path: "/docs"}) == :no_header
  end
end
