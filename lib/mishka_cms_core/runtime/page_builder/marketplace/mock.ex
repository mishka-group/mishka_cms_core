# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock do
  @moduledoc """
  The default `MishkaCmsCore.Runtime.PageBuilder.Marketplace` adapter: the design prototype's exact
  seed data, in memory.

  It exists so the Studio sheet can be built, styled and tested against real shapes before anyone
  decides what the backend is. Swapping in a real registry is one config key and changes no UI —
  which is the point of putting a behaviour here rather than reaching for HTTP.

  The tokens are the prototype's 32, values and usage counts included, because the panel's sorting,
  category counts and "unused" dimming are only meaningful over data with that spread.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @behaviour MishkaCmsCore.Runtime.PageBuilder.Marketplace

  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace.Token

  @tokens [
    {"color", "Ink", "ink", "#17161a", 42, false, ""},
    {"color", "Iris", "iris", "#5b57d6", 28, false, ""},
    {"color", "Paper", "paper", "#f6f5f2", 19, false, ""},
    {"color", "Green", "green", "#1f9d6b", 7, false, ""},
    {"color", "Amber", "amber", "#cf8a24", 4, false, ""},
    {"color", "Red", "red", "#c3373c", 3, false, ""},
    {"color", "Brand teal", "brand-teal", "#0b6f68", 2, true, ""},
    {"type", "Display", "display", "32 / 1.05", 6, false, "Aa"},
    {"type", "Title", "title", "20 / 1.2", 14, false, "Aa"},
    {"type", "Body", "body", "13.5 / 1.55", 96, false, "Aa"},
    {"type", "Caption", "caption", "11 / 1.4", 31, false, "Aa"},
    {"type", "Sans family", "font-sans", "Manrope", 0, false, "Aa"},
    {"type", "Mono family", "font-mono", "Space Grotesk", 0, false, "Aa"},
    {"space", "Unit", "space-1", "4px", 0, false, "4"},
    {"space", "Tight", "space-2", "8px", 52, false, "8"},
    {"space", "Base", "space-4", "16px", 88, false, "16"},
    {"space", "Loose", "space-6", "24px", 34, false, "24"},
    {"space", "Section", "space-10", "40px", 12, false, "40"},
    {"radius", "Small", "radius-sm", "8px", 24, false, "⌜"},
    {"radius", "Medium", "radius-md", "13px", 61, false, "⌜"},
    {"radius", "Large", "radius-lg", "18px", 19, false, "⌜"},
    {"radius", "Pill", "radius-full", "999px", 8, false, "⌜"},
    {"shadow", "Hairline", "shadow-xs", "0 1px 2px rgba(30,28,24,.04)", 47, false, "▤"},
    {"shadow", "Card", "shadow-md", "0 4px 12px rgba(30,28,24,.07)", 16, false, "▤"},
    {"shadow", "Overlay", "shadow-lg", "0 18px 46px rgba(20,18,26,.22)", 6, false, "▤"},
    {"motion", "Fast", "duration-fast", "140ms", 22, false, "→"},
    {"motion", "Base", "duration-base", "200ms", 9, false, "→"},
    {"motion", "Ease out", "ease-out", "cubic-bezier(.2,.8,.2,1)", 18, false, "→"},
    {"screen", "Mobile", "screen-sm", "560px", 0, false, "▭"},
    {"screen", "Tablet", "screen-md", "900px", 0, false, "▭"},
    {"screen", "Desktop", "screen-lg", "1180px", 0, false, "▭"},
    {"screen", "Wide", "screen-xl", "1440px", 0, true, "▭"}
  ]

  # The card fields the Studio shows. A real backend supplies these from its catalogue; the mock
  # carries the same shape so the panel is written once.
  # `palette` are the swatches shown under the card; `thumb`/`bars` are the skeleton the card draws
  # instead of a screenshot. They are deliberately separate: the palette is the preset's real colours,
  # the skeleton is a muted rendering of its layout, and using the palette for both made every
  # thumbnail shout.
  @presets [
    %{
      id: "editorial",
      name: "Editorial",
      blocks: 22,
      sections: 7,
      price: nil,
      rating: "4.8",
      size: "48 KB",
      updated: "Jul 2026",
      author: "Mishka Studio",
      category: "editorial",
      description: "Serif headlines, generous whitespace, single-column reading flow.",
      palette: ["#17161a", "#f6f5f2", "#5b57d6", "#cf8a24"],
      installed?: true,
      thumb: "#f6f5f2",
      bars: ["#e6e4de", "#dcdad2", "#c9c6bd"]
    },
    %{
      id: "saas-landing",
      name: "SaaS Landing",
      blocks: 31,
      sections: 9,
      price: nil,
      rating: "4.9",
      size: "62 KB",
      updated: "Jul 2026",
      author: "Mishka Studio",
      category: "marketing",
      description: "Hero with product shot, feature grid, pricing table, CTA band.",
      palette: ["#4f4bcc", "#eef1fc", "#1f9d6b", "#17161a"],
      installed?: true,
      thumb: "#eef1fc",
      bars: ["#c9c7f0", "#dcdbf5", "#b3b0e8"]
    },
    %{
      id: "docs-portal",
      name: "Docs Portal",
      blocks: 18,
      sections: 6,
      price: "$24",
      rating: "4.7",
      size: "41 KB",
      updated: "Jun 2026",
      author: "Chelekom Labs",
      category: "docs",
      description: "Sidebar navigation, versioned sections, search-first layout.",
      palette: ["#0f8f86", "#e6f5f2", "#17161a", "#f6f5f2"],
      installed?: false,
      thumb: "#e6f5f2",
      bars: ["#b6ded8", "#cfe9e4", "#9dd2ca"]
    },
    %{
      id: "commerce-pro",
      name: "Commerce Pro",
      blocks: 44,
      sections: 12,
      price: "$49",
      rating: "4.6",
      size: "96 KB",
      updated: "Jul 2026",
      author: "Chelekom Labs",
      category: "commerce",
      description: "Product grid, filters, cart drawer, checkout-ready blocks.",
      palette: ["#b03a76", "#fbe9f2", "#17161a", "#cf8a24"],
      installed?: false,
      thumb: "#fbe9f2",
      bars: ["#f0c6da", "#f5d9e6", "#e8aac8"]
    },
    %{
      id: "agency-dark",
      name: "Agency Dark",
      blocks: 27,
      sections: 8,
      price: "$39",
      rating: "4.5",
      size: "58 KB",
      updated: "May 2026",
      author: "Nord Kit",
      category: "marketing",
      description: "Full-bleed imagery on ink backgrounds with bold display type.",
      palette: ["#17161a", "#5b57d6", "#f6f5f2", "#c3373c"],
      installed?: false,
      thumb: "#24222a",
      bars: ["#3a3844", "#2e2c36", "#46434f"]
    },
    %{
      id: "changelog",
      name: "Changelog",
      blocks: 14,
      sections: 5,
      price: nil,
      rating: "4.4",
      size: "33 KB",
      updated: "Jul 2026",
      author: "Mishka Studio",
      category: "docs",
      description: "Timeline of releases with version anchors and tag filters.",
      palette: ["#5b57d6", "#f6f5f2", "#1f9d6b", "#17161a"],
      installed?: true,
      thumb: "#f2f1fc",
      bars: ["#d8d6f2", "#e6e4f8", "#c5c2ec"]
    }
  ]

  @packages [
    %{
      id: "chelekom-datatable",
      name: "Chelekom Datatable",
      category: "data",
      installed?: true,
      version: "v1.4.2",
      installs: "12.4k",
      rating: "4.9",
      size: "34 KB",
      deps: 2,
      updated: "2 days ago",
      author: "Chelekom Labs",
      description: "Sortable, filterable table with pagination and row selection."
    },
    %{
      id: "chelekom-charts",
      name: "Chelekom Charts",
      category: "data",
      installed?: false,
      version: "v0.9.1",
      installs: "6.1k",
      rating: "4.6",
      size: "58 KB",
      deps: 1,
      updated: "1 week ago",
      author: "Chelekom Labs",
      description: "Line, bar and donut charts that read from your own data source."
    },
    %{
      id: "chelekom-calendar",
      name: "Chelekom Calendar",
      category: "data",
      installed?: false,
      version: "v1.1.0",
      installs: "4.8k",
      rating: "4.5",
      size: "27 KB",
      deps: 0,
      updated: "3 weeks ago",
      author: "Chelekom Labs",
      description: "Month and week views with drag-to-create events."
    },
    %{
      id: "chelekom-editor",
      name: "Chelekom Rich Editor",
      category: "input",
      installed?: false,
      version: "v2.0.0",
      installs: "9.3k",
      rating: "4.7",
      size: "82 KB",
      deps: 3,
      updated: "5 days ago",
      author: "Chelekom Labs",
      description: "Block-based text editor with slash commands and pasted-HTML cleanup."
    },
    %{
      id: "chelekom-upload",
      name: "Chelekom Uploader",
      category: "input",
      installed?: false,
      version: "v1.2.4",
      installs: "7.7k",
      rating: "4.4",
      size: "19 KB",
      deps: 1,
      updated: "2 weeks ago",
      author: "Chelekom Labs",
      description: "Chunked uploads with progress, retry and direct-to-storage support."
    },
    %{
      id: "chelekom-maps",
      name: "Chelekom Maps",
      category: "media",
      installed?: false,
      version: "v0.7.0",
      installs: "2.9k",
      rating: "4.2",
      size: "44 KB",
      deps: 2,
      updated: "1 month ago",
      author: "Studio Nine",
      description: "Embedded maps with markers, clustering and a custom tile source."
    },
    %{
      id: "chelekom-player",
      name: "Chelekom Player",
      category: "media",
      installed?: false,
      version: "v1.0.3",
      installs: "5.2k",
      rating: "4.6",
      size: "31 KB",
      deps: 0,
      updated: "4 days ago",
      author: "Studio Nine",
      description: "Accessible video and audio player with captions and chapters."
    },
    %{
      id: "chelekom-auth",
      name: "Chelekom Auth Forms",
      category: "input",
      installed?: false,
      version: "v1.3.1",
      installs: "8.8k",
      rating: "4.8",
      size: "23 KB",
      deps: 1,
      updated: "6 days ago",
      author: "Chelekom Labs",
      description: "Sign-in, sign-up and reset forms wired to your own auth."
    },
    %{
      id: "chelekom-pricing",
      name: "Chelekom Pricing",
      category: "layout",
      installed?: false,
      version: "v1.0.0",
      installs: "3.4k",
      rating: "4.3",
      size: "16 KB",
      deps: 0,
      updated: "2 months ago",
      author: "Mishka",
      description: "Tiered pricing tables with a monthly and yearly toggle."
    }
  ]

  @snippets [
    %{
      id: 1,
      name: "Hero with CTA",
      scope: "<section.hero>",
      blocks: 4,
      size: "3.1 KB",
      when: "2 days ago",
      scope_type: "global",
      tint: "#eef1fc",
      template: ~s(<section class="hero"><h1>Headline</h1><p>Supporting line.</p></section>)
    },
    %{
      id: 2,
      name: "Pricing table",
      scope: "<section>",
      blocks: 7,
      size: "5.8 KB",
      when: "1 week ago",
      scope_type: "global",
      tint: "#e6f5f2",
      template:
        ~s(<section><h2>Pricing</h2><div class="grid"><div>Free</div><div>Pro</div></div></section>)
    },
    %{
      id: 3,
      name: "Footer · contact",
      scope: "<footer>",
      blocks: 3,
      size: "1.9 KB",
      when: "3 weeks ago",
      scope_type: "page",
      tint: "#fbf1df",
      template: ~s(<footer><p>Say hello</p></footer>)
    }
  ]

  @impl true
  def tokens(_site_id) do
    Enum.map(@tokens, fn {category, label, key, value, usage, custom?, glyph} ->
      Token.new!(%{
        category: category,
        label: label,
        key: key,
        value: value,
        usage: usage,
        custom?: custom?,
        glyph: glyph
      })
    end)
  end

  @impl true
  def presets(filters), do: filter_by(@presets, filters, :category)

  @impl true
  def packages(filters), do: filter_by(@packages, filters, :category)

  @impl true
  def snippets(filters), do: filter_by(@snippets, filters, :scope_type)

  # Nothing is really installed by a mock — it answers truthfully rather than pretending, so a
  # caller wiring the button up cannot mistake it for a working install path.
  @impl true
  def install(kind, id, _site_id, _actor),
    do:
      {:error,
       {:not_available,
        gettext("%{kind} %{id} cannot be installed from the mock registry", kind: kind, id: id)}}

  defp filter_by(items, filters, key) do
    case Map.get(filters, :category) || Map.get(filters, "category") do
      nil -> items
      "all" -> items
      value -> Enum.filter(items, &(Map.get(&1, key) == value))
    end
  end
end
