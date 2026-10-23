# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SiteLayout do
  @moduledoc """
  The one layout every page of a site is drawn in, `site-main`, and the contract through which a
  page, or the extension that owns it, hands that layout what only the page knows: the languages
  it is written in, and the bar under the header.

  `MishkaCmsCore.Install.StarterContent` writes the layout on every site, the installer's first
  one, a site created later in the admin and every dev site alike. It draws, top to bottom:

    1. the `site-header` component: the logo, the links, the language switcher, the dark toggle
       and the signed-in visitor's menu;
    2. the section bar, `section_bar/1`, when the page has one;
    3. the flash messages;
    4. `<main id="site-main">`, the content column, holding the page;
    5. the `site-footer` component.

  The sign-in pages are the exception: they hang on the `auth` layout of their own.

  ## The width

  The layout owns the content column. `<main>` is `mx-auto w-full max-w-[1160px] flex-1 px-8
  pb-24`: the home design's 1160 px, its 32 px gutters, and the 96 px under the last section.
  The header, the bar, the messages and the footer use the same 1160 px and 32 px, so every edge
  lines up, on a phone as on a desktop.

  So a page draws its sections straight into the column and NO outer container of its own:
  no `mx-auto`, no `max-w-*`, no side padding around the whole page. A container of the page's
  own doubles the gutters. What the page does own is its vertical rhythm, the room above its
  first section in particular: `pt-16` on the blog's list pages, `pt-[72px]` on the home page.

      <section class="flex flex-col gap-6 pt-16">
        <h1 class="font-newsreader text-[56px]">Notes, guides and long reads.</h1>
        …
      </section>

  A section that runs edge to edge, such as a band with a coloured or dotted background, adds
  `site-bleed`, a utility of the site's theme (`MishkaCmsCore.Install.StarterContent`). The
  section then reaches both edges of the window while what is inside it stays in the column, so
  it needs no container either:

      <section class="site-bleed bg-wash pt-[72px] pb-24 dark:bg-wash-dark">
        <div class="mx-auto max-w-[820px] text-center">…</div>
      </section>

  A section with `site-bleed` is a direct child of the page, not one nested inside a narrower
  box: it measures the column it breaks out of.

  ## What a page hands the layout

  `MishkaCmsWeb.RuntimeLive` calls `assign_frame/1` in every `handle_params/3`, after the
  page's language and `@query_params` are known and before its head is resolved. It fires
  `event/0` with the map `given/2` builds, reads the answer through `accept/2` and assigns:

    * `@page_languages`: the languages this page is in, each with its own address. The
      header's language switcher lists them (it is hidden for fewer than two), and the head's
      `hreflang` links are built from the same list (`MishkaCmsCore.Runtime.Seo`).
    * `@page_section_bar`: the bar under the header, or `nil` for none.

  A plugin is a `MishkaInstaller.Event.Hook` on `event/0`, registered by its application like
  any other. Its `call/1` is handed this map and returns it, changed or not:

    * `page`: the `:page` section of the page module's `__page_information__/0`, with
      `language` the language of THIS response. Read only.
    * `section`: the page's section, `page.section`: what an extension files its pages under
      (`"blog"`, `"document"`), as `MishkaCmsCore.Runtime.ExtensionProvision` writes it.
    * `record`: the kind of record the page shows, `"blog:post"`, from its `extra`
      (`MishkaCmsCore.Runtime.Seo.record_of/1`), or `nil` for none.
    * `extra`: the page's `extra`.
    * `params`: `@query_params`, the path's captures (`"slug"`, `"lang"`) and the query.
    * `language`: the language of this response, `page.language`.
    * `site_id`: the site's id.
    * `current_user`: the signed-in visitor, or `nil` for a guest. A plugin reads the other
      editions as this visitor, so an edition only some readers may open is offered to them.
    * `translations`: what the layout shows when no plugin says otherwise, already normalised
      (`translations/3`).
    * `section_bar`: `nil`.

  A plugin answers for the pages it owns: matched by `record`, by `section`, or by `page.path`.
  Every other page goes back untouched, and before anything is read. Nothing is cached: the
  event runs on every address, so a plugin reads what it needs with one query, and only for
  its own pages.

  ### `translations`

  The languages THIS record is written in, each at that edition's own address:

      %{language: "ar", path: "/ar/blog/category/akhbar", name: "العربية", title: "الأخبار"}

    * `language` (required): the language code;
    * `path` (required): the public address of that edition: a `/` path on the site, built
      with `MishkaCmsCore.Runtime.Languages.url/3` so it follows the site's URL mode, or an
      `http(s)://` address;
    * `name`: what the switcher calls the language; `Languages.name/1` of `language` when left
      out;
    * `title`: the record's own title in that language, shown as the link's tooltip.

  Include the edition being read: the switcher marks it as the current one. Leave out a language
  the record has no edition in: an English post with no Persian version answers `en` (and
  whatever else it has) and no `fa`, and the switcher offers no Persian. A language the site does
  not publish in is dropped, and so is an entry without a language or an address. Fewer than
  two languages left is `[]`, and the switcher is not drawn.

  What a plugin leaves untouched is today's behaviour: a page of the CMS's own is offered in
  each language it answers in, at the same path (`MishkaCmsCore.Runtime.PageEditions.alternates/3`).
  That is right for `/:lang/blog`, and wrong for `/:lang/blog/:slug`, where a post's
  translation has a slug of its own. So a page that shows a record answers for it here.

  ### `section_bar`

  `nil`, or a map of what the bar under the header shows. Everything in it is optional; a bar
  with nothing to show is not drawn:

    * `title`, `title_path`: the section's name, set in the home design's italic serif, and
      the address it links to;
    * `label`: what the links' `<nav>` is called to a screen reader; `title` when left out;
    * `links`: the section's places, drawn as the design's pill bar,
      `[%{label: "Posts", path: "/blog", current: true}, …]`; `current` marks the place the
      reader is in;
    * `crumbs`: a breadcrumb trail, `[%{label: "Docs", path: "/docs"}, %{label: "Install"}]`,
      the last one being the page the reader is on;
    * `component`: something the bar draws on its trailing side, which may be interactive. A
      `{module, function}` function component, called with `assigns`; or the name of one of the
      site's own components (`MishkaCmsCore.Runtime.LiveViewHelpers.component/1`), called with
      `assigns` as its attributes. A stateful one is drawn inside the page's LiveView and
      handles its own events, and needs an `id` among them;
    * `assigns`: what `component` is handed.

  Every address is a public one, as in `translations`.

  The bar's own markup is the core's, and its classes are in every site's stylesheet
  (`classes/0`). The classes a `component` draws with have to reach the stylesheet too. A
  component of the site that a page or a layout names is already in it; one that only the bar
  draws, and an Elixir function component, is not. List it on the
  `runtime:compile:content_components` event: the component's name in `components`, or the
  function component's classes in `classes`
  (`MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_components/1`).

  ### An example

  The blog's categories, which are one row per language joined by `language_group_id`:

      defmodule MishkaBlog.Plugins.PageFrame do
        use MishkaInstaller.Event.Hook, event: "runtime:page:frame", initial: %{priority: 50}

        alias MishkaCmsCore.Runtime.Languages

        @impl true
        def call(%{section: "blog"} = frame) do
          {:reply, :halt, %{frame | translations: translations(frame), section_bar: bar(frame)}}
        end

        def call(frame), do: {:reply, frame}

        # Every published edition of the category the slug names, the one being read included.
        defp translations(%{record: "blog:category", params: %{"slug" => slug}} = frame) do
          for category <- category_editions(frame.site_id, slug, frame.language) do
            %{
              language: category.language,
              path: Languages.url("/:lang/blog/category/:slug",
                %{"lang" => category.language, "slug" => category.slug}, frame.site_id),
              title: category.name
            }
          end
        end

        # A list page, `/:lang/blog`: the same path in every language is right.
        defp translations(frame), do: frame.translations

        # One read: the row the slug names in this language, then its `language_group_id`'s rows.
        defp category_editions(site_id, slug, language), do: …

        defp bar(%{language: language, site_id: site_id, page: page}) do
          url = &Languages.url(&1, %{"lang" => language}, site_id)

          %{
            title: "Blog",
            title_path: url.("/:lang/blog"),
            links: [
              %{label: "Posts", path: url.("/:lang/blog"), current: page.path == "/:lang/blog"},
              %{label: "Categories", path: url.("/:lang/blog/categories")},
              %{label: "Tags", path: url.("/:lang/blog/tags")},
              %{label: "People", path: url.("/:lang/blog/people")}
            ]
          }
        end
      end

  And the docs' bar, a breadcrumb with an interactive version picker beside it:

      %{
        crumbs: [%{label: "Docs", path: "/docs"}, %{label: workspace.name}],
        component: {MishkaDocument.Components, :version_select},
        assigns: %{id: "doc-version", versions: versions, current: version}
      }

  `{:reply, :halt, frame}` keeps later plugins from answering for a page this one owns;
  `{:reply, frame}` lets them. A plugin that raises, or an event whose plugins cannot run, leaves
  the page with what `given/2` holds.

  ## Putting an extension's pages on the layout

  `adopt_pages/3` hangs the pages of an extension's section that have no layout on the site's
  `site-main`. `MishkaCmsCore.Runtime.ExtensionProvision.ensure!/4` calls it after every run,
  so a site set up before an extension's pages carried a layout gets them on the frame on its
  next set-up or update. A page an admin moved to another layout is not touched, and neither is
  one another extension stamped (`MishkaCmsCore.Runtime.PageProvision.provisioned_by/1`).
  `layout_id/1` is the row to write into a page an extension creates itself.
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query
  require Logger

  alias MishkaCmsCore.Runtime.{Languages, Layout, LiveViewHelpers, Page, PageProvision, Seo}
  alias MishkaInstaller.Event.Hook

  @event "runtime:page:frame"
  @layout_name "site-main"

  # A section holds a handful of pages; one page of results is every one an extension wrote.
  @row_limit 200

  @package %{page_code: :package}

  # EVERY CLASS THE BAR DRAWS WITH, in one place: a site's stylesheet is built from its own
  # templates, which name none of these, so `classes/0` hands them to it. Each colour that changes
  # in the dark is written with its `dark:` twin, as in the starter's markup.
  @outer "border-y border-edge dark:border-edge-dark"
  @inner "mx-auto flex w-full max-w-[1160px] flex-wrap items-center gap-x-5 gap-y-3 px-8 py-3"
  @title "shrink-0 font-newsreader text-[22px] leading-none italic text-fg dark:text-fg-dark"
  @nav "flex max-w-full items-center gap-1 overflow-x-auto rounded-[12px] border border-edge bg-surface p-1 dark:border-edge-dark dark:bg-surface-dark"
  @link "flex h-8 shrink-0 items-center rounded-[9px] px-3.5 text-[13.5px] font-medium whitespace-nowrap"
  @current "bg-chip-wash text-brand dark:bg-chip-wash-dark dark:text-brand-dark"
  @other "text-dim hover:text-fg dark:text-dim-dark dark:hover:text-fg-dark"
  @crumbs_nav "min-w-0"
  @crumbs "flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-[14.5px]"
  @crumb_item "flex min-w-0 items-center gap-2"
  @crumb "text-dim hover:text-fg dark:text-dim-dark dark:hover:text-fg-dark"
  @crumb_here "min-w-0 truncate font-medium text-fg dark:text-fg-dark"
  @separator "text-faint dark:text-faint-dark"
  @trailing "flex min-w-0 items-center gap-2 sm:ms-auto"

  @typedoc "One language of a page, as the header's switcher and the head's `hreflang` read it."
  @type translation :: %{
          language: String.t(),
          path: String.t(),
          name: String.t(),
          title: String.t() | nil
        }

  @typedoc "The bar under the header, as `section_bar/1` draws it."
  @type bar :: %{
          title: String.t() | nil,
          title_path: String.t() | nil,
          label: String.t() | nil,
          links: [%{label: String.t(), path: String.t(), current: boolean()}],
          crumbs: [%{label: String.t(), path: String.t() | nil}],
          component: {module(), atom()} | String.t() | nil,
          assigns: map()
        }

  @typedoc "What a page hands its layout: `@page_languages` and `@page_section_bar`."
  @type frame :: %{translations: [translation()], section_bar: bar() | nil}

  @doc "The event a page's frame is resolved through, once per `handle_params/3`."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The name of the layout every page of a site hangs on."
  @spec layout_name() :: String.t()
  def layout_name, do: @layout_name

  @doc """
  The id of `site_id`'s `site-main` layout, or `nil` for a site that has none. An archived one is
  none: nothing is drawn in it.

  For an extension writing a page of its own: `layout_id: SiteLayout.layout_id(site.id)`.
  """
  @spec layout_id(String.t() | nil) :: String.t() | nil
  def layout_id(site_id) when is_binary(site_id) do
    Layout
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^@layout_name and site_id == ^site_id)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false, page: [limit: 1])
    |> Map.fetch!(:results)
    |> case do
      [%{id: id} | _rest] -> id
      [] -> nil
    end
  end

  def layout_id(_no_site), do: nil

  @doc """
  The map `event/0` is called with for `page`, before any plugin has answered. See the moduledoc
  for each key.

  `page` is the `:page` section of a page module's `__page_information__/0`, with the language
  of this response. Options: `:site_id`, `:current_user`, `:extra` (the page's `extra`),
  `:params` (`@query_params`) and `:translations`, the page's own editions
  (`MishkaCmsCore.Runtime.PageEditions.alternates/3`), which `translations/3` normalises.
  """
  @spec given(map(), keyword()) :: map()
  def given(page, opts) do
    site_id = Keyword.get(opts, :site_id)
    extra = Keyword.get(opts, :extra) || %{}

    %{
      page: page,
      section: Map.get(page, :section),
      record: Seo.record_of(extra),
      extra: extra,
      params: Keyword.get(opts, :params) || %{},
      language: Map.get(page, :language),
      site_id: site_id,
      current_user: Keyword.get(opts, :current_user),
      translations: translations(Keyword.get(opts, :translations, []), site_id),
      section_bar: nil
    }
  end

  @doc """
  What `page` hands its layout: `given/2`, then the plugins on `event/0`, then `accept/2`.
  Takes the options `given/2` takes.
  """
  @spec frame(map(), keyword()) :: frame()
  def frame(page, opts) do
    given = given(page, opts)

    @event
    |> Hook.call(given)
    |> accept(given)
  end

  @doc """
  The map a plugin on `event/0` returned, read against the one it was given.

    * `translations`: the given list when the plugin left it as it was; otherwise the plugin's,
      through `translations/3` with only the site's languages kept. Anything but a list is the
      given one.
    * `section_bar`: the plugin's, through `section_bar_of/1`.

  Anything but a map is the given frame.
  """
  @spec accept(term(), map()) :: frame()
  def accept(%{} = answer, given) when not is_struct(answer) do
    %{
      translations: answered(Map.get(answer, :translations), given),
      section_bar: section_bar_of(Map.get(answer, :section_bar))
    }
  end

  def accept(_not_a_map, given), do: %{translations: given.translations, section_bar: nil}

  defp answered(same, %{translations: same}), do: same

  defp answered(translations, %{site_id: site_id}) when is_list(translations),
    do: translations(translations, site_id, only_site_languages: true)

  defp answered(_not_a_list, given), do: given.translations

  @doc """
  The page's frame, assigned to `socket` as `@page_languages` and `@page_section_bar`.

  For `MishkaCmsWeb.RuntimeLive`, which calls it in `handle_params/3` once the page, its
  language and `@query_params` are assigned and before the head is resolved: the head's
  `hreflang` links read `@page_languages` too. `@page_languages` holds the page's own editions
  until this replaces it with the frame's.
  """
  @spec assign_frame(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_frame(%Phoenix.LiveView.Socket{assigns: assigns} = socket) do
    %{translations: translations, section_bar: bar} =
      frame(assigns.page,
        site_id: assigns |> Map.get(:private, %{}) |> Map.get(:site_id),
        current_user: Map.get(assigns, :current_user),
        extra: Map.get(assigns, :extra),
        params: Map.get(assigns, :query_params),
        translations: Map.get(assigns, :page_languages) || []
      )

    Phoenix.Component.assign(socket, page_languages: translations, page_section_bar: bar)
  end

  @doc """
  `entries` as the switcher reads them: each a `t:translation/0`, one per language, in the
  order the site lists its languages (any other after them, by code), and `[]` for fewer than
  two.

  An entry needs a `language` that is a language code and a `path` that is an address, a `/`
  path or an `http(s)://` one; anything else is dropped. A missing `name` is `Languages.name/1`
  of the language. With `only_site_languages: true`, a language `site_id` does not publish in is
  dropped too.

      translations(
        [%{language: "fa", path: "/fa/blog/akhbar"}, %{language: "en", path: "/blog/news"}],
        site_id
      )
      #=> [%{language: "en", path: "/blog/news", name: "English", title: nil},
      #    %{language: "fa", path: "/fa/blog/akhbar", name: "Persian", title: nil}]
  """
  @spec translations([map()] | term(), String.t() | nil, keyword()) :: [translation()]
  def translations(entries, site_id, opts \\ []) do
    languages = Languages.site(site_id)
    only_site? = Keyword.get(opts, :only_site_languages, false)

    entries
    |> List.wrap()
    |> Enum.flat_map(&translation/1)
    |> Enum.filter(&(not only_site? or &1.language in languages))
    |> Enum.uniq_by(& &1.language)
    |> Enum.sort_by(&order(&1.language, languages))
    |> case do
      [_, _ | _] = many -> many
      _one_or_none -> []
    end
  end

  defp translation(%{} = entry) when not is_struct(entry) do
    with language when is_binary(language) <- field(entry, :language),
         true <- Languages.codes_or_empty?([language]),
         path when is_binary(path) <- field(entry, :path),
         true <- address?(path) do
      [
        %{
          language: language,
          path: path,
          name: text(field(entry, :name)) || Languages.name(language) || language,
          title: text(field(entry, :title))
        }
      ]
    else
      _not_a_translation -> []
    end
  end

  defp translation(_not_a_map), do: []

  defp order(language, languages) do
    case Enum.find_index(languages, &(&1 == language)) do
      nil -> {1, 0, language}
      index -> {0, index, language}
    end
  end

  @doc """
  `bar` as `section_bar/1` draws it: a `t:bar/0` with every key present, or `nil` when it is not a
  map or holds nothing to draw.

  A link needs a `label` and an address; a crumb a `label`, its `path` optional. A `component` is
  a `{module, function}` whose module exports that function with one argument, or a component's
  name; anything else is none. `assigns` is a map, `%{}` when left out. Keys may be atoms or
  strings.
  """
  @spec section_bar_of(term()) :: bar() | nil
  def section_bar_of(%{} = bar) when not is_struct(bar) do
    normalised = %{
      title: text(field(bar, :title)),
      title_path: address(field(bar, :title_path)),
      label: text(field(bar, :label)),
      links: bar |> field(:links) |> List.wrap() |> Enum.flat_map(&bar_link/1),
      crumbs: bar |> field(:crumbs) |> List.wrap() |> Enum.flat_map(&bar_crumb/1),
      component: component(field(bar, :component)),
      assigns: assigns_of(field(bar, :assigns))
    }

    case normalised do
      %{title: nil, links: [], crumbs: [], component: nil} -> nil
      drawn -> drawn
    end
  end

  def section_bar_of(_none), do: nil

  defp bar_link(%{} = link) when not is_struct(link) do
    with label when is_binary(label) <- text(field(link, :label)),
         path when is_binary(path) <- address(field(link, :path)) do
      [%{label: label, path: path, current: field(link, :current) == true}]
    else
      _not_a_link -> []
    end
  end

  defp bar_link(_not_a_map), do: []

  defp bar_crumb(%{} = crumb) when not is_struct(crumb) do
    case text(field(crumb, :label)) do
      nil -> []
      label -> [%{label: label, path: address(field(crumb, :path))}]
    end
  end

  defp bar_crumb(_not_a_map), do: []

  defp component({module, function} = component) when is_atom(module) and is_atom(function) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 1) do
      component
    else
      Logger.warning(
        "[SiteLayout] the section bar names #{inspect(component)}, which is no function component"
      )

      nil
    end
  end

  defp component(name) when is_binary(name), do: text(name)
  defp component(_none), do: nil

  defp assigns_of(%{} = assigns) when not is_struct(assigns), do: assigns
  defp assigns_of(_none), do: %{}

  @doc """
  The bar under the header, for the `site-main` layout:

      <MishkaCmsCore.Runtime.SiteLayout.section_bar bar={assigns[:page_section_bar]} site="acme" />

  Draws nothing for a page with no bar. `site` is the site's name, which a `component` given by
  name is looked up in.
  """
  attr :bar, :any, default: nil, doc: "`@page_section_bar`: a `t:bar/0`, or `nil`."
  attr :site, :string, default: nil, doc: "The site's name, for a component given by name."
  attr :id, :string, default: "site-section-bar"

  def section_bar(assigns) do
    assigns = assign(assigns, :bar, section_bar_of(assigns.bar))

    ~H"""
    <div :if={@bar} id={@id} data-role="site-section-bar" class={outer_class()}>
      <div class={inner_class()}>
        <.link :if={@bar.title && @bar.title_path} navigate={@bar.title_path} class={title_class()}>
          {@bar.title}
        </.link>
        <span :if={@bar.title && !@bar.title_path} class={title_class()}>{@bar.title}</span>
        <nav
          :if={@bar.links != []}
          aria-label={@bar.label || @bar.title || gettext("Section")}
          data-role="site-section-links"
          class={nav_class()}
        >
          <.link
            :for={link <- @bar.links}
            {destination(link.path)}
            aria-current={link.current && "page"}
            class={[link_class(), (link.current && current_class()) || other_class()]}
          >
            {link.label}
          </.link>
        </nav>
        <nav
          :if={@bar.crumbs != []}
          aria-label={gettext("Breadcrumb")}
          data-role="site-section-crumbs"
          class={crumbs_nav_class()}
        >
          <ol class={crumbs_class()}>
            <li
              :for={{crumb, index} <- Enum.with_index(@bar.crumbs)}
              class={crumb_item_class()}
            >
              <span :if={index > 0} aria-hidden="true" class={separator_class()}>/</span>
              <.link
                :if={crumb.path && index < length(@bar.crumbs) - 1}
                {destination(crumb.path)}
                class={crumb_class()}
              >
                {crumb.label}
              </.link>
              <span :if={!crumb.path && index < length(@bar.crumbs) - 1} class={crumb_class()}>
                {crumb.label}
              </span>
              <span
                :if={index == length(@bar.crumbs) - 1}
                aria-current="page"
                class={crumb_here_class()}
              >
                {crumb.label}
              </span>
            </li>
          </ol>
        </nav>
        <div :if={@bar.component} data-role="site-section-component" class={trailing_class()}>
          {draw(@bar, @site)}
        </div>
      </div>
    </div>
    """
  end

  # A PAGE OF THE SITE IS A LIVE NAVIGATION, in the language the reader is in: the bar's links never
  # change it. An address off the site is an ordinary link.
  defp destination("/" <> _ = path), do: %{navigate: path}
  defp destination(url), do: %{href: url}

  defp draw(%{component: {module, function}, assigns: assigns}, _site) do
    Phoenix.LiveView.TagEngine.component(
      Function.capture(module, function, 1),
      assigns,
      {__MODULE__, __ENV__.function, __ENV__.file, __ENV__.line}
    )
  end

  defp draw(%{component: name, assigns: assigns}, site) when is_binary(name) do
    Phoenix.LiveView.TagEngine.component(
      &LiveViewHelpers.component/1,
      Map.merge(assigns, %{component_name: name, site: site}),
      {__MODULE__, __ENV__.function, __ENV__.file, __ENV__.line}
    )
  end

  defp outer_class, do: @outer
  defp inner_class, do: @inner
  defp title_class, do: @title
  defp nav_class, do: @nav
  defp link_class, do: @link
  defp current_class, do: @current
  defp other_class, do: @other
  defp crumbs_nav_class, do: @crumbs_nav
  defp crumbs_class, do: @crumbs
  defp crumb_item_class, do: @crumb_item
  defp crumb_class, do: @crumb
  defp crumb_here_class, do: @crumb_here
  defp separator_class, do: @separator
  defp trailing_class, do: @trailing

  @doc """
  Every class `section_bar/1` draws with, for whatever builds a site's stylesheet
  (`MishkaCmsCore.Runtime.Compilers.TailwindCompiler`).
  """
  @spec classes() :: String.t()
  def classes do
    Enum.join(
      [
        @outer,
        @inner,
        @title,
        @nav,
        @link,
        @current,
        @other,
        @crumbs_nav,
        @crumbs,
        @crumb_item,
        @crumb,
        @crumb_here,
        @separator,
        @trailing
      ],
      " "
    )
  end

  @doc """
  Hangs the pages of `section` on `site` that have no layout on the site's `site-main`, and
  returns their paths. `[]` when the site has no `site-main`, or no such page.

  Takes the site record or its id. A page with a layout of its own is left as it is, whichever it
  is: an admin who moved one chose it. Options:

    * `:source`: the extension the pages are the provision of (`:mishka_blog`); a page another
      extension stamped (`MishkaCmsCore.Runtime.PageProvision.provisioned_by/1`) is left alone.
      A page nothing stamped, written before pages were stamped, is taken.
    * `:actor`: who to write as, through the action their own role uses, as
      `MishkaCmsCore.Runtime.ExtensionProvision` writes; the system when left out.

  Run it again and it changes nothing: every page it took has a layout now.

      SiteLayout.adopt_pages(site.id, "blog", source: :mishka_blog)
      #=> ["/:lang/blog", "/:lang/blog/:slug"]
  """
  @spec adopt_pages(map() | String.t(), String.t(), keyword()) :: [String.t()]
  def adopt_pages(site, section, opts \\ [])

  def adopt_pages(%{id: site_id}, section, opts), do: adopt_pages(site_id, section, opts)

  def adopt_pages(site_id, section, opts) when is_binary(site_id) and is_binary(section) do
    case layout_id(site_id) do
      nil ->
        []

      layout_id ->
        source = opts |> Keyword.get(:source) |> source()

        for page <- unframed(site_id, section),
            PageProvision.provisioned_by(page) in [nil, source] or is_nil(source) do
          adopt!(page, layout_id, site_id, Keyword.get(opts, :actor))
          page.path
        end
    end
  end

  defp source(nil), do: nil
  defp source(source), do: to_string(source)

  defp unframed(site_id, section) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and section == ^section and is_nil(layout_id))
    |> Ash.Query.sort(:path)
    |> Ash.read!(authorize?: false, page: [limit: @row_limit])
    |> Map.fetch!(:results)
  end

  # THE THREE ANSWERS `ExtensionProvision` WRITES BY: nobody is the system, a master writes the
  # master action, a site's admin their own site's under its tenant. Only the layout changes, and
  # the write says it is a package's, as the provision's page writes do.
  defp adopt!(page, layout_id, _site_id, nil) do
    page
    |> Ash.Changeset.for_update(:master_update, %{layout_id: layout_id},
      authorize?: false,
      context: @package
    )
    |> Ash.update!()
  end

  defp adopt!(page, layout_id, _site_id, %{site_id: nil} = actor) do
    page
    |> Ash.Changeset.for_update(:master_update, %{layout_id: layout_id},
      actor: actor,
      context: @package
    )
    |> Ash.update!()
  end

  defp adopt!(page, layout_id, site_id, actor) do
    page
    |> Ash.Changeset.for_update(:update, %{layout_id: layout_id},
      actor: actor,
      tenant: site_id,
      context: @package
    )
    |> Ash.update!()
  end

  defp address(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> if address?(trimmed), do: trimmed
    end
  end

  defp address(_not_text), do: nil

  # A path on the site, or an address on the web. A protocol-relative `//host` is neither: it is
  # another site written to look like a path.
  defp address?("//" <> _), do: false
  defp address?("/" <> _), do: true
  defp address?("http://" <> _), do: true
  defp address?("https://" <> _), do: true
  defp address?(_other), do: false

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_not_text), do: nil

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
