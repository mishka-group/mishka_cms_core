defmodule MishkaCmsCore.Dev.SiteBPages do
  @moduledoc """
  What `site-b` answers on top of the starter site: a knowledge base, and the three layout cases the
  other two sites do not show — a page on a GLOBAL layout, a page with NO layout at all, and a
  `lang` capture that is not the first segment.

  See `MishkaCmsCore.Dev.LocalhostPages` for why there is one module per site.
  """

  @nav [{"FAQ", "/faq"}, {"Status", "/status"}, {"Changelog", "/changelog"}]

  @doc "The header links the layout is built with — see `MishkaCmsCore.Install.StarterContent`."
  @spec nav() :: [{String.t(), String.t()}]
  def nav, do: @nav

  @doc "The pages, as `MishkaCmsCore.Runtime.PageProvision` definitions."
  @spec pages(%{atom() => [String.t()]}) :: [map()]
  def pages(_pictures), do: [faq(), guides(), status(), changelog(), embed()]

  @doc "The home page this site answers `/:lang` with — see `MishkaCmsCore.Dev.LocalhostPages.home/0`."
  @spec home() :: String.t()
  def home do
    ~S"""
    <section
      id="site-b-home"
      phx-hook="SiteBConsoleLogger"
      class="rounded-card border border-line bg-white px-8 py-12"
    >
      <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">Knowledge base</p>
      <h1 class="mt-3 font-display text-[34px] font-bold leading-[1.15] tracking-[-0.03em] text-ink">
        How this thing works
      </h1>
      <p class="mt-4 max-w-[620px] text-[15px] leading-relaxed text-ink-soft">
        Guides, answers and a status board. This site publishes in English only, and it keeps its
        guides at <code>/guides/:lang/*rest</code> — the language in the middle of the address.
      </p>
    </section>

    <section class="mt-6 grid gap-5 sm:grid-cols-2">
      <.link
        :for={
          {title, body, path} <- [
            {"Guides", "Every page under one address, however deep.",
             site_path("/guides/:lang/*rest", %{"lang" => @page.language, "rest" => "getting-started/install"})},
            {"FAQ", "The questions that arrive first.", site_path("/:lang/faq", @page.language)},
            {"Status", "What is up, what is not, in a table.", site_path("/:lang/status", @page.language)},
            {"Changelog", "What changed, and when.", site_path("/:lang/changelog", @page.language)}
          ]
        }
        navigate={path}
        class="rounded-card border border-line bg-white p-5 shadow-[0_1px_2px_rgba(30,28,24,0.04)] hover:border-accent"
      >
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">{title}</h2>
        <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">{body}</p>
      </.link>
    </section>
    """
  end

  defp faq do
    %{
      name: "FAQ",
      title: "FAQ",
      path: "/:lang/faq",
      section: "main",
      description: "The questions a knowledge base opens with.",
      format: :heex,
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
          Frequently asked
        </h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Start here. The long answers live in the guides.
        </p>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <.component
          component_name="chelekom-accordion"
          site="Global"
          id="faq-list"
          variant="bordered"
          color="natural"
        >
          <:item id="faq-start" title="Where do I start?">
            Read the install guide, then write your first page in the builder.
          </:item>
          <:item id="faq-languages" title="Can one page answer in several languages?">
            Yes. A path with a <code>:lang</code> segment answers in every language the site
            publishes in, and the switcher in the footer moves between them.
          </:item>
          <:item id="faq-support" title="Something is broken.">
            Check the status page first — it says what we already know about.
          </:item>
        </.component>
      </section>

      <p class="mt-6 text-[13px]">
        <.link
          navigate={site_path("/guides/:lang/*rest", %{"lang" => @page.language, "rest" => "getting-started/install"})}
          class="font-bold text-accent"
        >
          Open the guides →
        </.link>
      </p>
      """
    }
  end

  # `lang` IN THE MIDDLE OF THE PATH, which is the case a language that is always the first segment
  # would never catch: the resolver checks the capture NAMED `lang` wherever it sits, and everything
  # that builds a URL — the switcher, the alternates in the head — swaps that segment rather than
  # the first one.
  defp guides do
    %{
      name: "Guides",
      title: "Guides",
      path: "/guides/:lang/*rest",
      section: "docs",
      description: "The guides, with the language in the middle of the address.",
      format: :heex,
      template: ~S"""
      <article class="rounded-card border border-line bg-white px-7 py-8">
        <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">
          Guide · {@query_params["lang"]}
        </p>
        <h1 id="guide-rest" class="mt-3 font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
          {@query_params["rest"]}
        </h1>
        <p class="mt-3 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          This page lives at <code>/guides/:lang/*rest</code>. The language is the second segment and
          the rest of the address is the guide.
        </p>
        <ul class="mt-6 space-y-2 text-[13px]">
          <li :for={rest <- ["getting-started/install", "getting-started/first-page", "recipes/seo"]}>
            <.link
              navigate={site_path("/guides/:lang/*rest", %{"lang" => @page.language, "rest" => rest})}
              class="font-medium text-accent hover:underline"
            >
              {rest}
            </.link>
          </li>
        </ul>
        <p class="mt-6 text-[13px]">
          <.link navigate={site_path("/:lang/faq", @page.language)} class="font-bold text-accent">
            ← Back to the FAQ
          </.link>
        </p>
      </article>
      """
    }
  end

  defp status do
    %{
      name: "Status",
      title: "Status",
      path: "/:lang/status",
      section: "main",
      description: "A table with a badge per row — what a status page really looks like.",
      format: :heex,
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Status</h1>
        <p class="mt-2 text-[13.5px] text-ink-soft">Everything we run, and how it is doing.</p>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <.component component_name="chelekom-table" site="Global" id="status-table" color="natural">
          <:header>Service</:header>
          <:header>State</:header>
          <:header>Last checked</:header>
          <.component component_name="chelekom-tr" site="Global" :for={
            {service, state, colour, checked} <- [
              {"Website", "Operational", "success", "a minute ago"},
              {"Search", "Degraded", "warning", "two minutes ago"},
              {"Exports", "Down", "danger", "four minutes ago"},
              {"API", "Operational", "success", "a minute ago"}
            ]
          }>
            <.component component_name="chelekom-td" site="Global">{service}</.component>
            <.component component_name="chelekom-td" site="Global">
              <.component component_name="chelekom-badge" site="Global" color={colour}>
                {state}
              </.component>
            </.component>
            <.component component_name="chelekom-td" site="Global">{checked}</.component>
          </.component>
        </.component>
      </section>
      """
    }
  end

  # A GLOBAL LAYOUT, not this site's. The layout a page hangs on is a row like any other and it does
  # not have to belong to the site — which is invisible until a page uses one.
  defp changelog do
    %{
      name: "Changelog",
      title: "Changelog",
      path: "/:lang/changelog",
      section: "main",
      layout: :plain,
      description: "On the global layout every site can hang a page on.",
      format: :heex,
      template: ~S"""
      <article class="mx-auto w-full max-w-[720px] px-6 py-12">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Changelog</h1>
        <p class="mt-2 text-[13.5px] text-ink-soft">
          This page hangs on the GLOBAL <code>global-plain</code> layout, so it carries no site
          header or footer — the layout is a row, and a row does not have to belong to this site.
        </p>
        <section :for={
          {version, line} <- [
            {"0.4.0", "Sample pages arrive with the language in the path."},
            {"0.3.0", "The page builder learned to hold a draft."},
            {"0.2.0", "Multi-tenant sites, layouts and components."}
          ]
        }>
          <h2 class="mt-7 font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
            {version}
          </h2>
          <p class="mt-1 text-[13.5px] text-ink-soft">{line}</p>
        </section>
        <p class="mt-8 text-[13px]">
          <.link navigate={site_path("/:lang", @page.language)} class="font-bold text-accent">
            ← Back to the site
          </.link>
        </p>
      </article>
      """
    }
  end

  # NO LAYOUT AT ALL, which is what an embeddable page wants: the runtime renders it inside the
  # application's own shell and nothing else is added to it.
  defp embed do
    %{
      name: "Embed",
      title: "Embed",
      path: "/:lang/embed",
      section: "main",
      layout: nil,
      description: "No layout at all — the case an embeddable widget needs.",
      format: :heex,
      template: ~S"""
      <div class="rounded-[18px] border border-[#ecebe6] bg-white p-6">
        <h1 class="font-display text-[17px] font-bold tracking-[-0.02em] text-[#1b1a18]">
          A page with no layout
        </h1>
        <p class="mt-2 text-[13.5px] text-[#57544d]">
          No header, no footer, no site chrome. Its own classes are written out rather than taken
          from the theme, because a page meant for somebody else's document cannot assume this
          site's stylesheet came with it.
        </p>
        <p class="mt-4 text-[13px]">
          <.link navigate={site_path("/:lang/status", @page.language)} class="font-bold text-[#5b57d6]">
            Status →
          </.link>
        </p>
      </div>
      """
    }
  end
end
