# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Elements do
  @moduledoc """
  The plain HTML an author reaches for constantly — a `section`, a column grid, a heading, a list.

  ## Why this exists

  The editor had two ways to put something on a page and neither of them was "an empty box". The
  palette lists a UI kit's components; `MishkaCmsCore.Runtime.PageBuilder.Blocks` lists whole
  finished sections. To get a `<section>` of your own you had to drop a Hero and delete everything
  inside it, or open the Code window and type. Every other builder — Elementor's Layout group,
  Gantry's structural particles — puts the primitives first, because they are what a page is
  actually made of; the finished sections are the shortcut, not the foundation.

  ## What an element is

  The same `%{id, title, category, description, template}` shape a block has, so one panel lists
  both and one search covers both. The difference is intent: a block arrives finished and is edited
  down, an element arrives empty and is built up.

  Plain HTML and Tailwind utilities only, for the same reason blocks are: an element that reached
  for a kit component would fail on an install without that kit, and every node here has to be
  something the Inspector already knows how to style. `<.form>` and `<.input>` are inside that rule
  rather than outside it: they are `Phoenix.Component.form/1` and
  `MishkaCmsCore.CoreComponents.input/1`, imported into every compiled page and resolved by the
  editing canvas, so they are there on every install — the standing `<.link>` already has.

  ## What the Forms elements are

  A form is a real Phoenix form: `for={assigns[:form_form]}` names the page assign that holds what
  the visitor typed, `as={:form}` scopes the params, and the two `phx-*` names are the handlers
  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` generates from the markup. All five names come
  from one seed, minted and renumbered by
  `MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming`, so a second form on the page cannot share the
  first one's assign. `el-form` therefore ships with a field and a button in it rather than empty:
  the five attributes are the point of it, and an empty one teaches none of them.

  The bare controls — `el-input`, `el-textarea`, `el-select`, `el-checkbox`, `el-radio-group` — keep
  a literal `name`, because a palette card and a hover preview render them on their own, outside any
  form. `MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement` rewrites that name into a binding
  on the way in, and wraps the control in a form first when it is dropped where there is none.

  ## Two rules that decide whether these are usable at all

  **Containers ship empty, and the canvas draws them anyway.** An empty `<section>` is zero pixels
  tall, so without help it cannot be clicked, cannot be dropped into, and looks like the drop
  failed. `MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive` gives any childless container a dashed
  outline and a minimum height while editing — never in preview, and never for a void tag like
  `<img>`, which is childless on purpose.

  **Text elements ship with words in them.** An empty `<p>` has the same problem and no good answer:
  a paragraph is its text. They arrive saying what they are, and the first thing an author does is
  type over it — which is exactly what the inline text editor is for.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  # The one styled Send button: `el-submit`, the button inside `el-form`, and what
  # `MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement.send_button/0` inserts. It reads
  # "Sending…" while its form is sent, so a second click cannot send it twice.
  @send ~s(<button type="submit" phx-disable-with="Sending…" class="rounded-lg bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white">Send</button>)

  @type element :: %{
          id: String.t(),
          title: String.t(),
          category: String.t(),
          description: String.t(),
          template: String.t()
        }

  # The one width every layout in this project agrees on — the same value `Blocks` and `PageStarter`
  # use, so a section built by hand lines up with a section dropped from the library.
  @wrap "mx-auto w-full max-w-6xl px-6"

  @elements [
    # ---- Layout ------------------------------------------------------------------------------
    %{
      id: "el-section",
      title: gettext_noop("Section"),
      category: gettext_noop("Layout"),
      description: gettext_noop("A band across the page. The usual outermost wrapper."),
      template: ~s(<section class="py-16"></section>)
    },
    %{
      id: "el-container",
      title: gettext_noop("Container"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Centred, width-capped, with side padding."),
      template: ~s(<div class="#{@wrap}"></div>)
    },
    %{
      id: "el-main",
      title: gettext_noop("Main"),
      category: gettext_noop("Layout"),
      description: gettext_noop("The page's primary content. One per page."),
      template: ~s(<main class="py-12"></main>)
    },
    %{
      id: "el-article",
      title: gettext_noop("Article"),
      category: gettext_noop("Layout"),
      description: gettext_noop("A self-contained piece — a post, a card's body."),
      template: ~s(<article class="py-8"></article>)
    },
    %{
      id: "el-aside",
      title: gettext_noop("Aside"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Content beside the main thread — a sidebar."),
      template: ~s(<aside class="py-8"></aside>)
    },
    %{
      id: "el-header",
      title: gettext_noop("Header"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Introductory content for the page or a section."),
      template: ~s(<header class="py-6"></header>)
    },
    %{
      id: "el-footer",
      title: gettext_noop("Footer"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Closing content for the page or a section."),
      template: ~s(<footer class="py-10"></footer>)
    },
    %{
      id: "el-nav",
      title: gettext_noop("Nav"),
      category: gettext_noop("Layout"),
      description: gettext_noop("A group of navigation links."),
      template: ~s(<nav class="flex items-center gap-6"></nav>)
    },
    %{
      id: "el-div",
      title: gettext_noop("Box"),
      category: gettext_noop("Layout"),
      description: gettext_noop("A plain div, for when nothing more specific fits."),
      template: ~s(<div></div>)
    },
    %{
      id: "el-columns-2",
      title: gettext_noop("2 columns"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Side by side on desktop, stacked on mobile."),
      template: ~s(<div class="grid gap-6 md:grid-cols-2"><div></div><div></div></div>)
    },
    %{
      id: "el-columns-3",
      title: gettext_noop("3 columns"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Three across on desktop, stacked on mobile."),
      template: ~s(<div class="grid gap-6 md:grid-cols-3"><div></div><div></div><div></div></div>)
    },
    %{
      id: "el-columns-4",
      title: gettext_noop("4 columns"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Four across on desktop, stacked on mobile."),
      template:
        ~s(<div class="grid gap-6 md:grid-cols-4"><div></div><div></div><div></div><div></div></div>)
    },
    %{
      id: "el-row",
      title: gettext_noop("Row"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Children in a line, vertically centred."),
      template: ~s(<div class="flex items-center gap-4"></div>)
    },
    %{
      id: "el-stack",
      title: gettext_noop("Stack"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Children one under the next, evenly spaced."),
      template: ~s(<div class="flex flex-col gap-4"></div>)
    },
    %{
      id: "el-spacer",
      title: gettext_noop("Spacer"),
      category: gettext_noop("Layout"),
      description: gettext_noop("Empty vertical room between two things."),
      template: ~s(<div class="h-16"></div>)
    },
    %{
      id: "el-divider",
      title: gettext_noop("Divider"),
      category: gettext_noop("Layout"),
      description: gettext_noop("A horizontal rule."),
      template: ~s(<hr class="my-8 border-slate-200" />)
    },

    # ---- Text --------------------------------------------------------------------------------
    %{
      id: "el-h1",
      title: gettext_noop("H1"),
      category: gettext_noop("Text"),
      description: gettext_noop("The page's one top-level heading."),
      template: ~s(<h1 class="text-4xl font-bold tracking-tight text-slate-900">Heading</h1>)
    },
    %{
      id: "el-h2",
      title: gettext_noop("H2"),
      category: gettext_noop("Text"),
      description: gettext_noop("A section heading."),
      template: ~s(<h2 class="text-3xl font-bold tracking-tight text-slate-900">Heading</h2>)
    },
    %{
      id: "el-h3",
      title: gettext_noop("H3"),
      category: gettext_noop("Text"),
      description: gettext_noop("A sub-section heading."),
      template: ~s(<h3 class="text-2xl font-semibold text-slate-900">Heading</h3>)
    },
    %{
      id: "el-h4",
      title: gettext_noop("H4"),
      category: gettext_noop("Text"),
      description: gettext_noop("A fourth-level heading."),
      template: ~s(<h4 class="text-xl font-semibold text-slate-900">Heading</h4>)
    },
    %{
      id: "el-h5",
      title: gettext_noop("H5"),
      category: gettext_noop("Text"),
      description: gettext_noop("A fifth-level heading."),
      template: ~s(<h5 class="text-lg font-semibold text-slate-900">Heading</h5>)
    },
    %{
      id: "el-h6",
      title: gettext_noop("H6"),
      category: gettext_noop("Text"),
      description: gettext_noop("A sixth-level heading."),
      template: ~s(<h6 class="text-base font-semibold text-slate-900">Heading</h6>)
    },
    %{
      id: "el-paragraph",
      title: gettext_noop("Paragraph"),
      category: gettext_noop("Text"),
      description: gettext_noop("A run of body copy."),
      template: ~s(<p class="text-base leading-relaxed text-slate-600">Write something here.</p>)
    },
    %{
      id: "el-link",
      title: gettext_noop("Link"),
      category: gettext_noop("Text"),
      description: gettext_noop("An anchor. Set where it goes in the Inspector."),
      template: ~s(<a href="#" class="font-medium text-slate-900 underline">Read more</a>)
    },
    %{
      id: "el-list",
      title: gettext_noop("Bulleted list"),
      category: gettext_noop("Text"),
      description: gettext_noop("An unordered list with three items."),
      template:
        ~s(<ul class="list-disc space-y-1 pl-5 text-slate-600"><li>First item</li><li>Second item</li><li>Third item</li></ul>)
    },
    %{
      id: "el-list-ordered",
      title: gettext_noop("Numbered list"),
      category: gettext_noop("Text"),
      description: gettext_noop("An ordered list with three items."),
      template:
        ~s(<ol class="list-decimal space-y-1 pl-5 text-slate-600"><li>First item</li><li>Second item</li><li>Third item</li></ol>)
    },
    %{
      id: "el-quote",
      title: gettext_noop("Quote"),
      category: gettext_noop("Text"),
      description: gettext_noop("A pulled quotation."),
      template:
        ~s(<blockquote class="border-l-4 border-slate-300 pl-4 text-lg italic text-slate-700">Something worth repeating.</blockquote>)
    },

    # ---- Media -------------------------------------------------------------------------------
    %{
      id: "el-image",
      title: gettext_noop("Image"),
      category: gettext_noop("Media"),
      description: gettext_noop("Pick the file from Assets after placing it."),
      template: ~s(<img src="" alt="" class="w-full rounded-lg" />)
    },
    %{
      id: "el-figure",
      title: gettext_noop("Figure"),
      category: gettext_noop("Media"),
      description: gettext_noop("An image with a caption under it."),
      template:
        ~s(<figure class="space-y-2"><img src="" alt="" class="w-full rounded-lg" /><figcaption class="text-sm text-slate-500">Caption</figcaption></figure>)
    },

    # ---- Forms -------------------------------------------------------------------------------
    %{
      id: "el-form",
      title: gettext_noop("Form"),
      category: gettext_noop("Forms"),
      description: gettext_noop("A working form with one field. Rename it in the Inspector."),
      template:
        ~s(<.form :let={f} id="form" as={:form} for={assigns[:form_form]} phx-change="form_validate" phx-submit="form_submit" class="space-y-4"><.input field={f[:field]} type="text" label="Label" />) <>
          @send <> "</.form>"
    },
    %{
      id: "el-fieldset",
      title: gettext_noop("Fieldset"),
      category: gettext_noop("Forms"),
      description: gettext_noop("Groups related fields under a legend."),
      template:
        ~s(<fieldset class="space-y-3 rounded-lg border border-slate-200 p-4"><legend class="px-1 text-sm font-semibold text-slate-700">Details</legend></fieldset>)
    },
    %{
      id: "el-label",
      title: gettext_noop("Label"),
      category: gettext_noop("Forms"),
      description: gettext_noop("Names a field. Set its For to that field's id."),
      template: ~s(<label for="" class="block text-sm font-medium text-slate-700">Label</label>)
    },
    %{
      id: "el-input",
      title: gettext_noop("Text input"),
      category: gettext_noop("Forms"),
      description: gettext_noop("A single line. Bound to the form it lands in."),
      template:
        ~s(<input type="text" name="field" class="w-full rounded-lg border border-slate-300 px-3 py-2" />)
    },
    %{
      id: "el-textarea",
      title: gettext_noop("Text area"),
      category: gettext_noop("Forms"),
      description: gettext_noop("Several lines. Bound to the form it lands in."),
      template:
        ~s(<textarea name="message" rows="4" class="w-full rounded-lg border border-slate-300 px-3 py-2"></textarea>)
    },
    %{
      id: "el-select",
      title: gettext_noop("Select"),
      category: gettext_noop("Forms"),
      description: gettext_noop("One of a list."),
      template:
        ~s(<select name="choice" class="w-full rounded-lg border border-slate-300 px-3 py-2"><option value="">Choose…</option></select>)
    },
    %{
      id: "el-checkbox",
      title: gettext_noop("Checkbox"),
      category: gettext_noop("Forms"),
      description: gettext_noop("A yes or no. Sends false when it is left unticked."),
      template:
        ~s(<label class="flex items-center gap-2 text-sm text-slate-700"><input type="hidden" name="agree" value="false" data-cast="boolean" /><input type="checkbox" name="agree" value="true" data-cast="boolean" class="size-4 rounded border-slate-300" />I agree</label>)
    },
    %{
      id: "el-radio-group",
      title: gettext_noop("Radio group"),
      category: gettext_noop("Forms"),
      description: gettext_noop("One of a few, all sharing one name."),
      template:
        ~s(<fieldset class="space-y-2"><legend class="text-sm font-medium text-slate-700">Choose one</legend><label class="flex items-center gap-2 text-sm text-slate-700"><input type="radio" name="choice" value="one" class="size-4 border-slate-300" />First</label><label class="flex items-center gap-2 text-sm text-slate-700"><input type="radio" name="choice" value="two" class="size-4 border-slate-300" />Second</label></fieldset>)
    },
    %{
      id: "el-submit",
      title: gettext_noop("Submit button"),
      category: gettext_noop("Forms"),
      description: gettext_noop("Sends the form to the page's handler."),
      template: @send
    },

    # ---- Dynamic -----------------------------------------------------------------------------
    # THE TWO EXPRESSIONS A LAYOUT AND A COMPONENT ARE BUILT ON HAD NO WAY IN. `{@inner_content}` is
    # the whole point of a layout — it is where the page goes — and `render_slot(@inner_block)` is
    # where a component's content goes. Both could be SEEN in a document that already had one,
    # selected, moved and deleted; neither could be put there except by opening the code drawer and
    # typing it, which is the surface this editor exists to make unnecessary.
    #
    # `sections` is what keeps each one where it means something. Offering `@inner_content` on a page
    # would be offering an assign that page will never be handed, and an author who took it would
    # get a document that does not compile.
    %{
      id: "el-inner-content",
      title: gettext_noop("Page content"),
      category: gettext_noop("Dynamic"),
      sections: ["layout"],
      description:
        gettext_noop("Where the page this layout wraps is rendered. Every layout needs one."),
      template: "{@inner_content}"
    },
    %{
      id: "el-inner-block",
      title: gettext_noop("Component content"),
      category: gettext_noop("Dynamic"),
      sections: ["component"],
      description: gettext_noop("Where whatever is put inside this component is rendered."),
      template: "{render_slot(@inner_block)}"
    },
    %{
      id: "el-attr",
      title: gettext_noop("Property value"),
      category: gettext_noop("Dynamic"),
      sections: ["component"],
      description:
        gettext_noop(
          "One of this component's own declared attributes. Rename it in the inspector."
        ),
      template: "{@title}"
    },
    %{
      id: "el-assign",
      title: gettext_noop("Expression"),
      category: gettext_noop("Dynamic"),
      description:
        gettext_noop("Any Elixir the document can evaluate. Edit its source in the inspector."),
      template: "{@assign}"
    }
  ]

  @doc """
  Every shipped element, in the order the panel lists them.

  The whole catalogue, whatever section it belongs to — which is what a check over "every element"
  has to mean. Use `for_section/1` to ask what a particular document may place.
  """
  @spec all() :: [element()]
  def all, do: @elements

  @doc """
  Every element the given section can use, in the order the panel lists them.

  MOST ELEMENTS BELONG EVERYWHERE and say nothing; a `<section>` is a `<section>` in all four
  documents. The ones that declare `sections` are the exception, and they are exceptions for a
  reason a reader can check: `{@inner_content}` names an assign only a LAYOUT is handed, so offering
  it on a page would be offering a document that will not compile.

  A section has to be NAMED. It used to be an optional argument defaulting to `nil`, and `nil` meant
  "only the ones that belong everywhere" — so the catalogue-wide checks, which pass no section,
  quietly stopped covering the three elements that declare one.
  """
  @spec for_section(String.t()) :: [element()]
  def for_section(section),
    do: Enum.filter(@elements, &(section in Map.get(&1, :sections, [section])))

  @doc "The categories the section's elements fall into, in order."
  @spec categories(String.t() | nil) :: [String.t()]
  def categories(section \\ nil)
  def categories(nil), do: all() |> Enum.map(& &1.category) |> Enum.uniq()
  def categories(section), do: section |> for_section() |> Enum.map(& &1.category) |> Enum.uniq()

  # `search/2` and `categories/1` both take an optional section, and both mean the same thing by
  # leaving it out: the whole catalogue.
  defp listed(nil), do: all()
  defp listed(section), do: for_section(section)

  @doc """
  Elements matching a search string, `nil` or `""` meaning all of them.

  Title and description are both searched, so "column" finds the grids and "sidebar" finds `aside`
  — an author looking for a thing rarely knows what the tag is called.
  """
  @spec search(String.t() | nil, String.t() | nil) :: [element()]
  def search(query, section \\ nil)

  def search(query, section) when query in [nil, ""], do: listed(section)

  def search(query, section) do
    needle = query |> String.trim() |> String.downcase()

    Enum.filter(listed(section), fn element ->
      shown?(element.title, needle) or shown?(element.description, needle) or
        String.contains?(element.id, needle)
    end)
  end

  defp shown?(text, needle) do
    [text, Gettext.gettext(MishkaCmsCore.Gettext, text)]
    |> Enum.any?(&String.contains?(String.downcase(&1), needle))
  end

  @doc """
  One element by id, or `nil`.

  Unfiltered on purpose: this answers "what is `el-inner-content`", which a drop that has already
  happened needs regardless of which panel offered it.
  """
  @spec get(String.t()) :: element() | nil
  def get(id), do: Enum.find(@elements, &(&1.id == id))
end
