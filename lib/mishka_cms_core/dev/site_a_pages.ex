# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.SiteAPages do
  @moduledoc """
  What `site-a` answers on top of the starter site: a small company, with a services list, one page
  per service and a team page built out of the site's own media library.

  A second site exists in the dev seeds to make the tenant boundary visible — the same component
  names, the same layout name and the same addresses, all resolving to this site's own rows. See
  `MishkaCmsCore.Dev.LocalhostPages` for why one module per site.
  """

  @nav [{"Services", "/services"}, {"Team", "/team"}]

  @doc "The header links the layout is built with — see `MishkaCmsCore.Install.StarterContent`."
  @spec nav() :: [{String.t(), String.t()}]
  def nav, do: @nav

  @doc """
  The pages, as `MishkaCmsCore.Runtime.PageProvision` definitions.

  `pictures` is `MishkaCmsCore.Dev.SeedMedia.images/1` for this site — the team page is written out
  of it, so the faces on it are rows in this site's own library rather than paths into a directory
  that may hold nothing.
  """
  @spec pages(%{atom() => [String.t()]}) :: [map()]
  def pages(pictures), do: [services(), service(), team(pictures)]

  @doc "The home page this site answers `/:lang` with — see `MishkaCmsCore.Dev.LocalhostPages.home/0`."
  @spec home() :: String.t()
  def home do
    ~S"""
    <section
      id="site-a-home"
      phx-hook="SiteAConsoleLogger"
      class="rounded-card border border-line bg-white px-8 py-14"
    >
      <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">Studio</p>
      <h1 class="mt-3 max-w-[680px] font-display text-[38px] font-bold leading-[1.15] tracking-[-0.03em] text-ink">
        We build the thing, then we keep it running
      </h1>
      <p class="mt-4 max-w-[600px] text-[15px] leading-relaxed text-ink-soft">
        A second site on the same node, with its own components, its own hooks and its own
        languages. Everything below belongs to this tenant and to no other.
      </p>
      <div class="mt-7 flex flex-wrap items-center gap-3">
        <.link
          navigate={site_path("/:lang/services", @page.language)}
          class="rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
        >
          What we do
        </.link>
        <.link
          navigate={site_path("/:lang/team", @page.language)}
          class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
        >
          Meet the team
        </.link>
      </div>
    </section>

    <section class="mt-6 grid gap-5 md:grid-cols-3">
      <.link
        :for={
          {title, body, slug} <- [
            {"Design", "Interfaces that say what they do.", "design"},
            {"Engineering", "Elixir, Phoenix and the Ash Framework.", "engineering"},
            {"Support", "We answer on the day you write.", "support"}
          ]
        }
        navigate={site_path("/:lang/services/:slug", %{"lang" => @page.language, "slug" => slug})}
        class="rounded-card border border-line bg-white p-5 shadow-[0_1px_2px_rgba(30,28,24,0.04)] hover:border-accent"
      >
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">{title}</h2>
        <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">{body}</p>
      </.link>
    </section>

    <section class="mt-6 flex flex-wrap items-center justify-between gap-4 rounded-card border border-line bg-white p-6">
      <div>
        <h2 class="font-display text-[20px] font-bold tracking-[-0.02em] text-ink">
          Start with a conversation
        </h2>
        <p class="mt-1 text-[13.5px] text-ink-soft">Tell us what you are making and who it is for.</p>
      </div>
      <.link
        navigate={site_path("/:lang/contact", @page.language)}
        class="rounded-[9px] bg-accent px-4 py-2 text-[12px] font-bold text-white"
      >
        Get in touch
      </.link>
    </section>
    """
  end

  defp services do
    %{
      name: "Services",
      title: "Services",
      path: "/:lang/services",
      section: "main",
      description: "What the company does, each one linking to a page of its own.",
      format: :heex,
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Services</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Four things we do. Each one is the same page underneath — one row answering
          <code>/services/:slug</code>.
        </p>
      </section>

      <section class="mt-6 grid gap-5 sm:grid-cols-2">
        <article
          :for={
            {slug, title, line} <- [
              {"strategy", "Strategy", "Where the site is going, and what it is for."},
              {"design", "Design", "A look that survives the second page."},
              {"engineering", "Engineering", "Elixir, Phoenix and the Ash Framework."},
              {"support", "Support", "Somebody answers when it breaks."}
            ]
          }
          class="rounded-card border border-line bg-white p-6 shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
        >
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">{title}</h2>
          <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">{line}</p>
          <p class="mt-4">
            <.link
              navigate={site_path("/:lang/services/:slug", %{"lang" => @page.language, "slug" => slug})}
              class="text-[13px] font-bold text-accent"
            >
              What that means →
            </.link>
          </p>
        </article>
      </section>
      """,
      translations: %{"fr" => services_fr()}
    }
  end

  defp services_fr do
    %{
      name: "Nos services",
      title: "Nos services",
      description: "Quatre choses que nous faisons, chacune reliée à sa propre page.",
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Services</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Quatre choses que nous faisons. Chacune est la même page en coulisses — une seule ligne
          qui répond à <code>/services/:slug</code>.
        </p>
      </section>

      <section class="mt-6 grid gap-5 sm:grid-cols-2">
        <article
          :for={
            {slug, title, line} <- [
              {"strategy", "Stratégie", "Où va le site, et à quoi il sert."},
              {"design", "Design", "Une identité qui tient jusqu'à la deuxième page."},
              {"engineering", "Ingénierie", "Elixir, Phoenix et le framework Ash."},
              {"support", "Support", "Quelqu'un répond quand ça casse."}
            ]
          }
          class="rounded-card border border-line bg-white p-6 shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
        >
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">{title}</h2>
          <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">{line}</p>
          <p class="mt-4">
            <.link
              navigate={"/fr/services/#{slug}"}
              class="text-[13px] font-bold text-accent"
            >
              Ce que cela veut dire →
            </.link>
          </p>
        </article>
      </section>
      """
    }
  end

  defp service do
    %{
      name: "Service",
      title: "Service",
      path: "/:lang/services/:slug",
      section: "main",
      description: "One service — the captured segment, read off the address.",
      format: :heex,
      template: ~S"""
      <.component component_name="chelekom-breadcrumb" site="Global" id="service-crumbs">
        <:item link={site_path("/:lang", @page.language)} title="Home">Home</:item>
        <:item link={site_path("/:lang/services", @page.language)} title="Services">Services</:item>
        <:item title={@query_params["slug"]}>{@query_params["slug"]}</:item>
      </.component>

      <article class="mt-5 rounded-card border border-line bg-white px-7 py-8">
        <h1 id="service-slug" class="font-display text-[30px] font-bold tracking-[-0.03em] text-ink">
          {@query_params["slug"]}
        </h1>
        <p class="mt-3 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Every service reads its own name out of the address. Write the real copy in the builder,
          or split this into a page per service when they stop being alike.
        </p>
        <p class="mt-6">
          <.link
            navigate={site_path("/:lang/contact", @page.language)}
            class="inline-block rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
          >
            Ask about it
          </.link>
        </p>
      </article>
      """,
      translations: %{"fr" => service_fr()}
    }
  end

  defp service_fr do
    %{
      name: "Prestation",
      title: "Prestation",
      description: "Un service — le segment capturé, lu directement dans l'adresse.",
      template: ~S"""
      <.component component_name="chelekom-breadcrumb" site="Global" id="service-crumbs">
        <:item link={"/fr"} title="Accueil">Accueil</:item>
        <:item link={"/fr/services"} title="Services">Services</:item>
        <:item title={@query_params["slug"]}>{@query_params["slug"]}</:item>
      </.component>

      <article class="mt-5 rounded-card border border-line bg-white px-7 py-8">
        <h1 id="service-slug" class="font-display text-[30px] font-bold tracking-[-0.03em] text-ink">
          {@query_params["slug"]}
        </h1>
        <p class="mt-3 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Chaque service lit son propre nom dans l'adresse. Écrivez le vrai texte dans l'éditeur, ou
          scindez cette page en une page par service le jour où elles cesseront de se ressembler.
        </p>
        <p class="mt-6">
          <.link
            navigate={"/fr/contact"}
            class="inline-block rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
          >
            Nous en parler
          </.link>
        </p>
      </article>
      """
    }
  end

  # THE FACES ARE THE SITE'S OWN MEDIA ROWS. A seeded page that named a file under `priv/static`
  # drew a picture that exists in this application and in no other, and a page written before the
  # library was filled draws none at all — which is why this takes them as an argument rather than
  # reading a directory.
  defp team(pictures) do
    faces = Map.get(pictures, :avatar, [])

    %{
      name: "Team",
      title: "Team",
      path: "/:lang/team",
      section: "main",
      description: "Who does the work, with pictures from this site's media library.",
      format: :heex,
      template: ~s"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">The team</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Small enough that you will speak to the person doing the work.
        </p>
      </section>

      <section class="mt-6 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
      #{Enum.map_join(members(faces), "\n", &member_card/1)}
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="mb-4 font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          How we got here
        </h2>
        <.component component_name="chelekom-timeline" site="Global" id="team-timeline" color="primary">
          <.component component_name="chelekom-timeline-section" site="Global" title="2021">
            Two people and one client.
          </.component>
          <.component component_name="chelekom-timeline-section" site="Global" title="2023">
            The first site built entirely in the page builder.
          </.component>
          <.component component_name="chelekom-timeline-section" site="Global" title="Today">
            Four of us, and the CMS you are reading this in.
          </.component>
        </.component>
      </section>
      """,
      translations: %{"fr" => team_fr(faces)}
    }
  end

  defp team_fr(faces) do
    %{
      name: "L'équipe",
      title: "L'équipe",
      description: "Qui fait le travail, avec des photos tirées de la médiathèque de ce site.",
      template: ~s"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">L'équipe</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Une équipe assez petite pour que vous parliez directement à la personne qui fait le
          travail.
        </p>
      </section>

      <section class="mt-6 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
      #{Enum.map_join(members_fr(faces), "\n", &member_card/1)}
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="mb-4 font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          Notre parcours
        </h2>
        <.component component_name="chelekom-timeline" site="Global" id="team-timeline" color="primary">
          <.component component_name="chelekom-timeline-section" site="Global" title="2021">
            Deux personnes et un seul client.
          </.component>
          <.component component_name="chelekom-timeline-section" site="Global" title="2023">
            Le premier site entièrement construit dans l'éditeur de pages.
          </.component>
          <.component component_name="chelekom-timeline-section" site="Global" title="Aujourd'hui">
            Nous sommes quatre, et voici le CMS dans lequel vous lisez ceci.
          </.component>
        </.component>
      </section>
      """
    }
  end

  defp members(faces) do
    [
      {"Ada", "Strategy"},
      {"Bahar", "Design"},
      {"Cyrus", "Engineering"},
      {"Dara", "Support"}
    ]
    |> Enum.with_index()
    |> Enum.map(fn {{name, role}, index} -> {name, role, Enum.at(faces, index)} end)
  end

  # SAME NAMES, FRENCH TITLES — Design and Support are unchanged because they read the same in
  # French; a translation copies the word only where the word itself does not.
  defp members_fr(faces) do
    [
      {"Ada", "Stratégie"},
      {"Bahar", "Design"},
      {"Cyrus", "Ingénierie"},
      {"Dara", "Support"}
    ]
    |> Enum.with_index()
    |> Enum.map(fn {{name, role}, index} -> {name, role, Enum.at(faces, index)} end)
  end

  defp member_card({name, role, nil}) do
    ~s"""
      <article class="rounded-card border border-line bg-white p-5 text-center">
          <p class="font-display text-[15px] font-bold text-ink">#{name}</p>
          <p class="mt-1 text-[12.5px] text-muted">#{role}</p>
        </article>\
    """
  end

  defp member_card({name, role, face}) do
    ~s"""
      <article class="rounded-card border border-line bg-white p-5 text-center">
          <img src="#{face}" alt="#{name}" class="mx-auto h-16 w-16 rounded-full object-cover" />
          <p class="mt-3 font-display text-[15px] font-bold text-ink">#{name}</p>
          <p class="mt-1 text-[12.5px] text-muted">#{role}</p>
        </article>\
    """
  end
end
