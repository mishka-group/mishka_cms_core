# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.SeedsNavTest do
  @moduledoc """
  The links a dev site adds to its header: all of them in ONE `Dev` dropdown
  (`MishkaCmsCore.Install.StarterContent`'s grouped links), so what stands beside it is what a
  production install's header has.

  The host's `SeedsInstallTest` asserts the other half, that each link lands on a page the seeded
  site holds. Nothing here touches the database: the nav is a plain list.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Dev.{LocalhostPages, Seeds, SiteAPages, SiteBPages, StarterPages}

  @blog {"Blog", "/blog"}
  @docs {"Docs", "/docs"}
  @extensions [@blog, @docs]

  # EACH SITE, with the links it is for, in the order a developer reads them: the pages every dev
  # site has (About, Contact), then the site's own. Blog and Docs come last, when the build has the
  # extensions.
  @expected %{
    "localhost" => [
      {"About", "/about"},
      {"Contact", "/contact"},
      {"Showcase", "/showcase"},
      {"Pricing", "/pricing"},
      {"Gallery", "/gallery"},
      {"Messages", "/messages"}
    ],
    "site-a" => [
      {"About", "/about"},
      {"Contact", "/contact"},
      {"Showcase", "/showcase"},
      {"Services", "/services"},
      {"Team", "/team"}
    ],
    "site-b" => [
      {"About", "/about"},
      {"Contact", "/contact"},
      {"Showcase", "/showcase"},
      {"FAQ", "/faq"},
      {"Status", "/status"},
      {"Changelog", "/changelog"}
    ]
  }

  for {site, links} <- @expected do
    describe "#{site}" do
      test "holds all its links in one Dev group, and nothing else" do
        assert [%{label: "Dev", children: children}] = Seeds.nav(unquote(site), [])
        assert children == unquote(Macro.escape(links))
      end

      test "ends the group with the extensions' front pages, when the build has them" do
        assert [%{label: "Dev", children: children}] = Seeds.nav(unquote(site), @extensions)
        assert children == unquote(Macro.escape(links)) ++ @extensions
      end

      test "writes a path, not an address, so the site's URL mode makes it one" do
        [%{children: children}] = Seeds.nav(unquote(site), @extensions)

        for {_label, path} <- children, do: assert(path =~ ~r{\A/[a-z-]+\z}, path)
      end

      test "is the dev seeds' own list of this site's pages, in this site's modules" do
        module = %{"localhost" => LocalhostPages, "site-a" => SiteAPages, "site-b" => SiteBPages}
        [%{children: children}] = Seeds.nav(unquote(site), [])

        assert children == StarterPages.nav() ++ Map.fetch!(module, unquote(site)).nav()
      end

      # WHAT THIS BUILD HAS: the core alone has neither extension, a host with them has both.
      test "adds the extensions' pages only for the extensions this build holds" do
        base = unquote(Macro.escape(links))
        [%{children: children}] = Seeds.nav(unquote(site))

        assert Enum.take(children, length(base)) == base
        assert Enum.all?(Enum.drop(children, length(base)), &(&1 in @extensions))

        keys = Enum.map(Seeds.categories(), & &1.key)
        assert @blog in children == :blog in keys
        assert @docs in children == :document in keys
      end
    end
  end

  test "is one entry per site, so the header's row holds the dropdown and nothing before Docs" do
    for site <- Map.keys(@expected) do
      assert [%{label: "Dev"}] = Seeds.nav(site, @extensions)
      assert length(Seeds.nav(site, @extensions)) == 1
    end
  end
end
