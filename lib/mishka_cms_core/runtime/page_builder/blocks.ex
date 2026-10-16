# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Blocks do
  @moduledoc """
  Whole sections an author drops in one click — a hero, a feature row, a pricing table.

  The palette lists 183 components and the Studio's Presets tab is a catalogue of whole-page themes
  that nothing on disk supplies. Between the two there was nothing: to get a landing page you placed
  a grid, then a heading, then a paragraph, then a button, then set the column count, and repeated it
  for every band down the page. Elementor and Gantry both answer this with a section library, and it
  is the single thing that decides whether someone who is not a developer finishes a page.

  ## Why these are plain HTML and Tailwind

  A block that reached for `chelekom-card` would be a block that fails on an install without
  Chelekom, and the whole point of the kit-agnostic work is that no part of the editor assumes one
  kit. Every block here is `div`/`h2`/`p`/`a` with utility classes, so it renders on any install,
  and every node inside it is an ordinary element the Inspector already knows how to style. An
  author who does have a kit can replace any piece afterwards.

  ## What a block is

  A `%{id, title, category, template}` map. `template` is HEEx that `Tree.parse/1` accepts, and it
  may have several roots — `Tree.insert/4` splices them into the sibling list as ONE undoable op, so
  a fourteen-node hero arrives and leaves in a single step.

  Blocks are code, not content: they ship with the CMS, are the same for every tenant, and are never
  edited in place. Anything an author saves for reuse is a `MishkaCmsCore.Runtime.Snippet`, which is
  a different thing with a different lifetime.

  ## Why every block opens with a band tag

  `MishkaCmsCore.Runtime.PageBuilder.Placement` reads band-ness off the head node's tag, and a
  component head is not a band. A block whose template started with `<.form>` or a `<div>` would be
  treated as a leaf and land inside whatever was clicked rather than beside the other slices of the
  page, so every block here opens with a `<section>`, `<header>`, `<footer>` or `<main>`.

  ## What a form block is

  A real form rather than a picture of one. `<.form>` is `Phoenix.Component.form/1` and `<.input>` is
  `MishkaCmsCore.CoreComponents.input/1`; both are imported into every compiled page and both are
  resolved by the editing canvas, so a form block renders the same on the palette card, on the canvas
  and on the published page — on an install carrying no UI kit at all. An author who does have one
  swaps a field for the kit's own through the Inspector, per site.

  Five attributes carry everything a form needs and all five come from one seed the author types
  once: `contact` gives `id="contact-form"`, `as={:contact}`, `for={assigns[:contact_form]}`,
  `phx-change="contact_validate"` and `phx-submit="contact_submit"`.
  `MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming` mints and renumbers them, so dropping one
  block twice gives `contact` and `contact_2` rather than two forms sharing one page assign, and
  gives each form a token as it lands (`contact-k7m2q-validate`, `contact-k7m2q-submit`). The page
  compiler reads the markup back through `MishkaCmsCore.Runtime.PageBuilder.PageForms` and generates
  both handlers, so a dropped form works with no Elixir written anywhere.

  What is checked is the HTML constraint attributes already on the field — `required`, `minlength`,
  `maxlength`, `data-format` — declared once, enforced by the browser and re-checked on the server,
  so the two cannot disagree. `data-success` on the form node is what the visitor is told afterwards.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  @type block :: %{
          id: String.t(),
          title: String.t(),
          category: String.t(),
          description: String.t(),
          template: String.t()
        }

  @wrap "mx-auto w-full max-w-6xl px-6"

  @blocks [
    %{
      id: "hero-centred",
      title: gettext_noop("Hero"),
      category: gettext_noop("Header"),
      description: gettext_noop("Headline, a line of copy and two buttons."),
      template: """
      <section class="bg-white py-24">
        <div class="#{@wrap} text-center">
          <h1 class="mx-auto max-w-3xl text-5xl font-bold tracking-tight text-slate-900">
            Build the site you already pictured
          </h1>
          <p class="mx-auto mt-5 max-w-xl text-lg text-slate-600">
            Everything you need to publish, in one place. No plugins to wire together.
          </p>
          <div class="mt-9 flex items-center justify-center gap-3">
            <a href="#" class="rounded-lg bg-slate-900 px-6 py-3 text-sm font-semibold text-white">
              Get started
            </a>
            <a href="#" class="rounded-lg border border-slate-300 px-6 py-3 text-sm font-semibold text-slate-700">
              See how it works
            </a>
          </div>
        </div>
      </section>
      """
    },
    %{
      id: "features-three",
      title: gettext_noop("Features ×3"),
      category: gettext_noop("Content"),
      description: gettext_noop("Three columns of title and text."),
      template: """
      <section class="bg-white py-20">
        <div class="#{@wrap}">
          <h2 class="text-3xl font-bold tracking-tight text-slate-900">Why people stay</h2>
          <div class="mt-10 grid grid-cols-3 gap-8 max-md:grid-cols-1">
            <div>
              <h3 class="text-base font-semibold text-slate-900">Fast to start</h3>
              <p class="mt-2 text-sm leading-relaxed text-slate-600">
                Drop a section, change the words, publish. Nothing to install first.
              </p>
            </div>
            <div>
              <h3 class="text-base font-semibold text-slate-900">Yours to shape</h3>
              <p class="mt-2 text-sm leading-relaxed text-slate-600">
                Every piece is an ordinary element you can restyle or replace.
              </p>
            </div>
            <div>
              <h3 class="text-base font-semibold text-slate-900">Built to last</h3>
              <p class="mt-2 text-sm leading-relaxed text-slate-600">
                Versioned, previewable and safe to roll back at any point.
              </p>
            </div>
          </div>
        </div>
      </section>
      """
    },
    %{
      id: "features-four",
      title: gettext_noop("Features ×4"),
      category: gettext_noop("Content"),
      description: gettext_noop("A four-across row — the one people ask for first."),
      template: """
      <section class="bg-slate-50 py-20">
        <div class="#{@wrap}">
          <div class="grid grid-cols-4 gap-6 max-lg:grid-cols-2 max-sm:grid-cols-1">
            <div class="rounded-xl bg-white p-6">
              <h3 class="text-sm font-semibold text-slate-900">First</h3>
              <p class="mt-2 text-sm text-slate-600">A short line about this one.</p>
            </div>
            <div class="rounded-xl bg-white p-6">
              <h3 class="text-sm font-semibold text-slate-900">Second</h3>
              <p class="mt-2 text-sm text-slate-600">A short line about this one.</p>
            </div>
            <div class="rounded-xl bg-white p-6">
              <h3 class="text-sm font-semibold text-slate-900">Third</h3>
              <p class="mt-2 text-sm text-slate-600">A short line about this one.</p>
            </div>
            <div class="rounded-xl bg-white p-6">
              <h3 class="text-sm font-semibold text-slate-900">Fourth</h3>
              <p class="mt-2 text-sm text-slate-600">A short line about this one.</p>
            </div>
          </div>
        </div>
      </section>
      """
    },
    %{
      id: "media-split",
      title: gettext_noop("Text + image"),
      category: gettext_noop("Content"),
      description: gettext_noop("Copy on one side, a picture on the other."),
      template: """
      <section class="bg-white py-20">
        <div class="#{@wrap} grid grid-cols-2 items-center gap-12 max-md:grid-cols-1">
          <div>
            <h2 class="text-3xl font-bold tracking-tight text-slate-900">Made for the way you work</h2>
            <p class="mt-4 text-base leading-relaxed text-slate-600">
              Change a heading, swap a picture, move a row. The page you edit is the page visitors get.
            </p>
            <a href="#" class="mt-6 inline-block text-sm font-semibold text-slate-900 underline">
              Read the guide
            </a>
          </div>
          <div class="aspect-[4/3] w-full rounded-xl bg-slate-100"></div>
        </div>
      </section>
      """
    },
    %{
      id: "stats-row",
      title: gettext_noop("Stats"),
      category: gettext_noop("Content"),
      description: gettext_noop("Three numbers with labels."),
      template: """
      <section class="bg-slate-900 py-16">
        <div class="#{@wrap} grid grid-cols-3 gap-8 text-center max-sm:grid-cols-1">
          <div>
            <div class="text-4xl font-bold text-white">12k</div>
            <div class="mt-1 text-sm text-slate-400">Pages published</div>
          </div>
          <div>
            <div class="text-4xl font-bold text-white">99.9%</div>
            <div class="mt-1 text-sm text-slate-400">Uptime</div>
          </div>
          <div>
            <div class="text-4xl font-bold text-white">40ms</div>
            <div class="mt-1 text-sm text-slate-400">Median response</div>
          </div>
        </div>
      </section>
      """
    },
    %{
      id: "pricing-three",
      title: gettext_noop("Pricing"),
      category: gettext_noop("Commerce"),
      description: gettext_noop("Three plans, the middle one highlighted."),
      template: """
      <section class="bg-white py-20">
        <div class="#{@wrap}">
          <h2 class="text-center text-3xl font-bold tracking-tight text-slate-900">Simple pricing</h2>
          <div class="mt-12 grid grid-cols-3 gap-6 max-md:grid-cols-1">
            <div class="rounded-2xl border border-slate-200 p-8">
              <h3 class="text-sm font-semibold text-slate-500">Starter</h3>
              <div class="mt-3 text-4xl font-bold text-slate-900">Free</div>
              <a href="#" class="mt-8 block rounded-lg border border-slate-300 py-2.5 text-center text-sm font-semibold text-slate-700">
                Start now
              </a>
            </div>
            <div class="rounded-2xl border-2 border-slate-900 p-8">
              <h3 class="text-sm font-semibold text-slate-900">Team</h3>
              <div class="mt-3 text-4xl font-bold text-slate-900">$29</div>
              <a href="#" class="mt-8 block rounded-lg bg-slate-900 py-2.5 text-center text-sm font-semibold text-white">
                Choose Team
              </a>
            </div>
            <div class="rounded-2xl border border-slate-200 p-8">
              <h3 class="text-sm font-semibold text-slate-500">Business</h3>
              <div class="mt-3 text-4xl font-bold text-slate-900">$99</div>
              <a href="#" class="mt-8 block rounded-lg border border-slate-300 py-2.5 text-center text-sm font-semibold text-slate-700">
                Talk to us
              </a>
            </div>
          </div>
        </div>
      </section>
      """
    },
    %{
      id: "cta-band",
      title: gettext_noop("Call to action"),
      category: gettext_noop("Footer"),
      description: gettext_noop("One line and a button."),
      template: """
      <section class="bg-slate-100 py-16">
        <div class="#{@wrap} flex items-center justify-between gap-6 max-sm:flex-col max-sm:text-center">
          <h2 class="text-2xl font-bold tracking-tight text-slate-900">Ready when you are</h2>
          <a href="#" class="rounded-lg bg-slate-900 px-6 py-3 text-sm font-semibold text-white">
            Create your first page
          </a>
        </div>
      </section>
      """
    },
    %{
      id: "form-contact",
      sections: ["page"],
      title: gettext_noop("Contact form"),
      category: gettext_noop("Forms"),
      description: gettext_noop("Name, email and message, checked as the visitor types."),
      template: """
      <section class="py-16">
        <div class="#{@wrap} max-w-xl">
          <h2 class="text-2xl font-bold tracking-tight text-slate-900">Get in touch</h2>
          <p class="mt-2 text-slate-600">We answer every message.</p>
          <.form
            :let={f}
            id="contact-form"
            as={:contact}
            for={assigns[:contact_form]}
            phx-change="contact_validate"
            phx-submit="contact_submit"
            data-success="Thanks, we will be in touch."
            class="mt-8 space-y-5"
          >
            <.input field={f[:name]} type="text" label="Your name" required minlength="2" />
            <.input field={f[:email]} type="email" label="Email" required data-format="email" />
            <.input field={f[:message]} type="textarea" label="Message" required minlength="10" maxlength="2000" />
            <button type="submit" class="rounded-lg bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white">
              Send message
            </button>
          </.form>
        </div>
      </section>
      """
    },
    %{
      id: "form-fieldset",
      sections: ["page"],
      title: gettext_noop("Fieldset group"),
      category: gettext_noop("Forms"),
      description: gettext_noop("Related fields under a legend, inside a form."),
      template: """
      <section class="py-12">
        <div class="#{@wrap} max-w-xl">
          <.form
            :let={f}
            id="details-form"
            as={:details}
            for={assigns[:details_form]}
            phx-change="details_validate"
            phx-submit="details_submit"
            data-success="Saved."
            class="space-y-5"
          >
            <fieldset class="space-y-4 rounded-xl border border-slate-200 p-5">
              <legend class="px-1 text-sm font-semibold text-slate-700">Your details</legend>
              <.input field={f[:first_name]} type="text" label="First name" required minlength="2" />
              <.input field={f[:last_name]} type="text" label="Last name" required minlength="2" />
            </fieldset>
            <button type="submit" class="rounded-lg bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white">
              Save
            </button>
          </.form>
        </div>
      </section>
      """
    },
    %{
      id: "form-newsletter",
      sections: ["page"],
      title: gettext_noop("Newsletter signup"),
      category: gettext_noop("Forms"),
      description: gettext_noop("One email field and a button, on a line."),
      template: """
      <section class="bg-slate-50 py-14">
        <div class="#{@wrap} max-w-2xl">
          <h2 class="text-xl font-bold tracking-tight text-slate-900">Get the monthly note</h2>
          <p class="mt-2 text-sm text-slate-600">One email a month. Leave whenever you like.</p>
          <.form
            :let={f}
            id="newsletter-form"
            as={:newsletter}
            for={assigns[:newsletter_form]}
            phx-change="newsletter_validate"
            phx-submit="newsletter_submit"
            data-success="You're on the list."
            class="mt-6 flex items-end gap-3 max-sm:flex-col max-sm:items-stretch"
          >
            <div class="flex-1">
              <.input field={f[:email]} type="email" label="Email" required data-format="email" />
            </div>
            <button type="submit" class="mb-2 rounded-lg bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white">
              Subscribe
            </button>
          </.form>
        </div>
      </section>
      """
    },
    # THE SHAPE PEOPLE ASK FOR AND CANNOT BUILD. A field and a button that share one border and one
    # set of rounded corners is four decisions — the border goes on the ROW, the field and the button
    # give theirs up, the row hides what overflows its corners, and the field's own bottom margin
    # goes. Each is one utility and none of them is guessable, which is why the newsletter block
    # above ships the gapped version and this one ships the joined one.
    %{
      id: "form-subscribe-joined",
      sections: ["page"],
      title: gettext_noop("Subscribe box"),
      category: gettext_noop("Forms"),
      description: gettext_noop("An email field and a button sharing one rounded border."),
      template: """
      <section class="bg-white py-14">
        <div class="#{@wrap} max-w-xl">
          <h2 class="text-xl font-bold tracking-tight text-slate-900">Subscribe</h2>
          <p class="mt-2 text-sm text-slate-600">One email a month. Leave whenever you like.</p>
          <.form
            :let={f}
            id="subscribe-form"
            as={:subscribe}
            for={assigns[:subscribe_form]}
            phx-change="subscribe_validate"
            phx-submit="subscribe_submit"
            data-success="You're on the list."
            class="mt-6"
          >
            <div class="flex items-stretch overflow-hidden rounded-lg border border-slate-300 bg-white focus-within:border-slate-900 [&>div]:mb-0 [&>div]:flex-1">
              <.input
                field={f[:email]}
                type="email"
                placeholder="you@example.com"
                required
                data-format="email"
                class="w-full border-0 bg-transparent px-4 py-2.5 text-sm focus:outline-none"
              />
              <button type="submit" class="flex-none bg-slate-900 px-5 text-sm font-semibold text-white">
                Subscribe
              </button>
            </div>
          </.form>
        </div>
      </section>
      """
    },
    %{
      id: "footer-columns",
      title: gettext_noop("Footer"),
      category: gettext_noop("Footer"),
      description: gettext_noop("Three link columns and a line of small print."),
      template: """
      <footer class="bg-white py-14">
        <div class="#{@wrap}">
          <div class="grid grid-cols-3 gap-10 max-sm:grid-cols-1">
            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-slate-500">Product</h3>
              <a href="#" class="mt-3 block text-sm text-slate-600">Features</a>
              <a href="#" class="mt-2 block text-sm text-slate-600">Pricing</a>
            </div>
            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-slate-500">Company</h3>
              <a href="#" class="mt-3 block text-sm text-slate-600">About</a>
              <a href="#" class="mt-2 block text-sm text-slate-600">Contact</a>
            </div>
            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-slate-500">Legal</h3>
              <a href="#" class="mt-3 block text-sm text-slate-600">Privacy</a>
              <a href="#" class="mt-2 block text-sm text-slate-600">Terms</a>
            </div>
          </div>
          <p class="mt-10 border-t border-slate-200 pt-6 text-xs text-slate-500">
            © 2026 Your company. All rights reserved.
          </p>
        </div>
      </footer>
      """
    }
  ]

  @doc "Every shipped block, in the order the panel lists them — the whole catalogue."
  @spec all() :: [block()]
  def all, do: @blocks

  @doc """
  Every block the given section can use, in the order the panel lists them.

  MOST BLOCKS BELONG EVERYWHERE and say nothing; a hero is a hero in all four documents. The ones
  that declare `sections` are the exception, and they are exceptions for a reason a reader can
  check: the three form blocks ship `phx-change` and `phx-submit` bound to handlers, and
  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` is the only compiler that emits a
  `handle_event/3` — a Layout, a Component and an error page have no `events` column to hold one.
  Dropping one of those anywhere else produced markup whose form could never be submitted.

  The same rule `MishkaCmsCore.Runtime.PageBuilder.Elements.for_section/1` applies, for the same
  reason and with the same requirement that the section be named rather than defaulted.
  """
  @spec for_section(String.t()) :: [block()]
  def for_section(section),
    do: Enum.filter(@blocks, &(section in Map.get(&1, :sections, [section])))

  @doc "The categories present, in first-appearance order — the panel's filter chips."
  @spec categories(String.t() | nil) :: [String.t()]
  def categories(section \\ nil)
  def categories(nil), do: all() |> Enum.map(& &1.category) |> Enum.uniq()
  def categories(section), do: section |> for_section() |> Enum.map(& &1.category) |> Enum.uniq()

  @doc "One block by id, or `nil`."
  @spec fetch(String.t()) :: block() | nil
  def fetch(id), do: Enum.find(@blocks, &(&1.id == id))

  @doc """
  The blocks matching a category and a search string.

  `"all"` and a blank query both mean "everything", so the panel can pass its controls straight
  through without deciding what an empty filter means.
  """
  @spec search(String.t() | nil, String.t() | nil) :: [block()]
  def search(category, query), do: filter(@blocks, category, query)

  @doc """
  Filters ANY list of block-shaped entries the way `search/2` filters the built-in ones.

  The palette merges an extension's contributions in beside these, and a contributed block has to
  answer the category chips and the search box exactly as a built-in one does — which it cannot if
  the merge happens after the filtering.
  """
  @spec filter([block()], String.t() | nil, String.t() | nil) :: [block()]
  def filter(entries, category, query) do
    entries
    |> Enum.filter(&in_category?(&1, category))
    |> Enum.filter(&matches?(&1, query))
  end

  defp in_category?(_block, nil), do: true
  defp in_category?(_block, "all"), do: true
  defp in_category?(block, category), do: Map.get(block, :category) == category

  defp matches?(_block, nil), do: true
  defp matches?(_block, ""), do: true

  defp matches?(block, query) do
    needle = String.downcase(String.trim(query))

    needle == "" or
      Enum.any?(~w(title category description id)a, fn field ->
        block |> Map.get(field) |> haystacks(field) |> Enum.any?(&String.contains?(&1, needle))
      end)
  end

  # A contribution is not obliged to carry every field a built-in does.
  defp haystacks(value, :id) when is_binary(value), do: [String.downcase(value)]

  defp haystacks(value, _field) when is_binary(value) do
    [value, Gettext.gettext(MishkaCmsCore.Gettext, value)] |> Enum.map(&String.downcase/1)
  end

  defp haystacks(_missing, _field), do: []
end
