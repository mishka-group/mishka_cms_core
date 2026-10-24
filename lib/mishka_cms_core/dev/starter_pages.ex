# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.StarterPages do
  @moduledoc """
  The pages every dev site has beside its home: the about, contact and privacy pages a first install
  used to be given and no longer is.

  A production install writes ONE page, the home (`MishkaCmsCore.Install.StarterContent`), and a dev
  site's `/` is that same page, written by the same run. The dev seeds still want these three — the
  contact page is the form machinery's plainest test, and the pages the showcase links to land on
  them — so they live here, and `MishkaCmsCore.Dev.Seeds` hands `pages/2` to
  `StarterContent.seed!/2` as its `:extra_pages` option. They are written the way the installer
  writes its home: stamped, answering every language the site publishes in, held by name and by
  address, so the seeding path stays the one a real install runs.

  They are written in the admin palette (`bg-ground`, `text-ink`, `rounded-card`), which the
  starter's theme still declares for exactly this and for the error pages.
  """

  @nav [{"About", "/about"}, {"Contact", "/contact"}]

  @doc """
  The header links to these pages, as `StarterContent.seed!/2`'s `:nav` takes them. The production
  header has none of its own.
  """
  @spec nav() :: [{String.t(), String.t()}]
  def nav, do: @nav

  @doc """
  The three definitions, in the order they are written: `about` when the site has one of its own
  (`localhost` does) and else the plain one, then contact and privacy. The home is not among them:
  `StarterContent` writes its own, first.

  `brand` is what the plain about page prints, as the site's name.
  """
  @spec pages(String.t(), String.t() | nil) :: [map()]
  def pages(brand, about \\ nil) do
    [
      %{
        name: "About",
        title: "About",
        path: "/:lang/about",
        description: "What this site is.",
        template: about || about_template(brand)
      },
      %{
        name: "Contact",
        title: "Contact",
        path: "/:lang/contact",
        description: "A form that really submits, with errors and a confirmation.",
        template: contact_template()
      },
      %{
        name: "Privacy",
        title: "Privacy",
        path: "/:lang/privacy",
        description: "What the site does with what a visitor sends it.",
        template: privacy_template()
      }
    ]
  end

  defp about_template(brand) do
    ~s"""
    <article class="rounded-card border border-line bg-white p-8">
      <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
        About #{brand}
      </h1>
      <p class="mt-4 text-[15px] leading-relaxed text-ink-soft">
        This page is here so you have something to edit. Replace it with who you are, what you
        make and why somebody should read on.
      </p>
      <dl class="mt-8 grid gap-5 sm:grid-cols-3">
        <div :for={
          {term, detail} <- [
            {"Runs on", "Elixir, Phoenix and the Ash Framework"},
            {"Edited in", "The page builder, on this same site"},
            {"Published", "When you say so, and not before"}
          ]
        }>
          <dt class="text-[11.5px] font-bold uppercase tracking-[0.14em] text-muted">{term}</dt>
          <dd class="mt-1 text-[13.5px] text-ink">{detail}</dd>
        </div>
      </dl>
      <p class="mt-8">
        <.link navigate={site_path("/:lang", @page.language)} class="text-[13px] font-bold text-accent">
          ← Back home
        </.link>
      </p>
    </article>
    """
  end

  # THE FIELDS ARE HAND-WRITTEN `<input>`s, not `<.input>`: the host's field component styles
  # itself with class names from a CSS framework this project ships no bundle for, so its
  # boxes would render as bare unstyled text. The form machinery reads a plain control's
  # `name` (and the `f[:key]` in its value) exactly as it reads a kit field's `field=`.
  defp contact_template do
    ~S"""
    <div class="grid gap-6 md:grid-cols-[1.2fr_1fr]">
      <.form
        :let={f}
        id="contact-form"
        as={:contact}
        for={assigns[:contact_form]}
        phx-change="contact-k7m2q-validate"
        phx-submit="contact-k7m2q-submit"
        data-success="Thank you — we have your message."
        class="rounded-card border border-line bg-white p-7"
      >
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
          Get in touch
        </h1>
        <p class="mt-2 text-[13.5px] text-ink-soft">
          Tell us what you need. Everything marked required has to be filled in.
        </p>

        <label for="contact-name" class="mt-6 block text-[12.5px] font-bold text-ink">Name</label>
        <input
          type="text"
          id="contact-name"
          name="contact[name]"
          value={f[:name].value}
          required
          minlength="2"
          maxlength="80"
          class="mt-1.5 w-full rounded-[9px] border border-line bg-white px-3 py-2 text-[13.5px] text-ink outline-none focus:border-accent"
        />
        <p :for={{message, _opts} <- form_errors(f[:name])} class="mt-1 text-[12px] text-bad">
          {message}
        </p>

        <label for="contact-email" class="mt-5 block text-[12.5px] font-bold text-ink">
          Email
        </label>
        <input
          type="email"
          id="contact-email"
          name="contact[email]"
          value={f[:email].value}
          required
          data-format="email"
          class="mt-1.5 w-full rounded-[9px] border border-line bg-white px-3 py-2 text-[13.5px] text-ink outline-none focus:border-accent"
        />
        <p :for={{message, _opts} <- form_errors(f[:email])} class="mt-1 text-[12px] text-bad">
          {message}
        </p>

        <label for="contact-message" class="mt-5 block text-[12.5px] font-bold text-ink">
          Message
        </label>
        <textarea
          id="contact-message"
          name="contact[message]"
          required
          minlength="10"
          maxlength="2000"
          rows="5"
          class="mt-1.5 w-full rounded-[9px] border border-line bg-white px-3 py-2 text-[13.5px] text-ink outline-none focus:border-accent"
        >{f[:message].value}</textarea>
        <p :for={{message, _opts} <- form_errors(f[:message])} class="mt-1 text-[12px] text-bad">
          {message}
        </p>

        <button
          type="submit"
          id="contact-submit"
          class="mt-6 rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
        >
          Send message
        </button>
      </.form>

      <aside class="rounded-card border border-line bg-white p-7">
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          Other ways
        </h2>
        <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">
          Edit this panel in the builder and put your real address, your hours and anything else
          a visitor needs here.
        </p>
        <p class="mt-6 text-[13px]">
          <.link navigate={site_path("/:lang/privacy", @page.language)} class="font-bold text-accent">
            How we handle what you send →
          </.link>
        </p>
      </aside>
    </div>
    """
  end

  defp privacy_template do
    ~S"""
    <article class="rounded-card border border-line bg-white p-8">
      <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Privacy</h1>
      <p class="mt-4 text-[15px] leading-relaxed text-ink-soft">
        This is a placeholder, not legal advice. Say what you collect, why you collect it, how
        long you keep it and who you share it with — then delete this sentence.
      </p>
      <section :for={
        {heading, body} <- [
          {"What we collect",
           "Whatever the contact form asks for, and nothing the site has not asked you for."},
          {"Why we keep it", "To answer you. Say here how long that is."},
          {"Who else sees it", "Name every service the message passes through."}
        ]
      }>
        <h2 class="mt-7 font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          {heading}
        </h2>
        <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">{body}</p>
      </section>
      <p class="mt-8">
        <.link navigate={site_path("/:lang", @page.language)} class="text-[13px] font-bold text-accent">
          ← Back home
        </.link>
      </p>
    </article>
    """
  end
end
