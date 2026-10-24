# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.ShowcasePagesTest do
  @moduledoc """
  The demo that used to stand at `/` on every dev site, now at `/:lang/showcase` on each of them.

  `/` is the home a first install writes (`MishkaCmsCore.Dev.StarterPagesTest` asserts that, and the
  host's `SeedsInstallTest` asserts it for the three seeded sites). What is asserted here is the
  other half: that each site's own module still hands the seeds its demo, at its own address, on the
  layout every page of the site shares, with a way in from the header.

  Nothing here touches the database: the modules answer plain maps.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Dev.{LocalhostPages, SiteAPages, SiteBPages, StarterPages}

  # Each site, with the id its showcase section carries, the hook it names and the languages its
  # showcase is written in besides English.
  @sites [
    {LocalhostPages, "localhost-showcase", "LocalhostConsoleLogger", ["fa"]},
    {SiteAPages, "site-a-showcase", "SiteAConsoleLogger", ["fr"]},
    {SiteBPages, "site-b-showcase", "SiteBConsoleLogger", []}
  ]

  for {module, id, hook, languages} <- @sites do
    describe "#{inspect(module)}" do
      test "has no home of its own to write in place of the installer's" do
        refute function_exported?(unquote(module), :home, 0)
      end

      test "hands the seeds its demo at /:lang/showcase, on the site's one layout" do
        assert [page] = showcase(unquote(module))

        assert page.name == "Showcase"
        assert page.section == "main"
        assert page.format == :heex

        # NO `:layout` KEY is `site-main`: `MishkaCmsCore.Dev.Seeds` reads `Map.get(page, :layout, :main)`.
        assert Map.get(page, :layout, :main) == :main
        assert Map.get(page, :active, true)

        assert page.template =~ ~s(id="#{unquote(id)}")
        assert page.template =~ ~s(phx-hook="#{unquote(hook)}")
      end

      test "writes the showcase in the languages its site publishes in, and no other" do
        [page] = showcase(unquote(module))

        assert page |> Map.get(:translations, %{}) |> Map.keys() |> Enum.sort() ==
                 unquote(languages)

        for {_language, translation} <- Map.get(page, :translations, %{}) do
          assert translation.template =~ ~s(id="#{unquote(id)}")
          assert translation.template =~ "/:lang/"
          assert translation.template != page.template
        end
      end

      test "links to it from the header, beside the demos it already linked to" do
        nav = unquote(module).nav()

        assert {"Showcase", "/showcase"} in nav
        assert nav -- [{"Showcase", "/showcase"}] != [], "the demo links are still there"
      end

      test "has a page behind every link the header carries" do
        paths = Enum.map(unquote(module).pages(%{}) ++ StarterPages.pages("site"), & &1.path)

        for {label, path} <- StarterPages.nav() ++ unquote(module).nav() do
          assert ("/:lang" <> path) in paths, "#{label} links to #{path}, which no page answers"
        end
      end

      test "answers /:lang/showcase once, and /:lang not at all" do
        pages = unquote(module).pages(%{})

        assert Enum.count(pages, &(&1.path == "/:lang/showcase")) == 1
        refute Enum.any?(pages, &(&1.path == "/:lang")), "the home is the installer's alone"
      end
    end
  end

  defp showcase(module), do: module.pages(%{}) |> Enum.filter(&(&1.path == "/:lang/showcase"))
end
