# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageEditions do
  @moduledoc """
  A page in the other languages it is published in: what `<html lang dir>`, the hreflang links and a
  language switcher read, and what "Add translation" writes.

  ## Two ways to publish a page in several languages

  An edition is a page row with a `language` and a `language_group_id`, the group's key being its
  master's own id — the model blog posts and documents already use (see
  `MishkaCmsCore.LanguageEditions`). The author chooses the URL:

    * one literal path per language — `/about` in English, `/fa/about` in Persian, two rows;
    * one pattern for all of them — `/:lang/about`, one row whose template branches on
      `@query_params["lang"]`.

  Both are read the same way. A literal edition is in the language its row names. A pattern edition
  is in the languages `served_languages/2` gives it — every language its site has
  (`MishkaCmsCore.Runtime.Languages`) for a page marked as serving them all, its own otherwise —
  each at the URL the pattern makes when the `lang` capture is swapped, wherever in the path that
  capture sits, with every other capture kept as the visitor asked for it. Where both answer one
  language the literal row wins, as it does in the resolver.

  ## In a template

  `MishkaCmsWeb.RuntimeLive` assigns `@page.language` — the language THIS response is in, so the
  captured one on a pattern page — and `@page_languages`, which is `alternates/3` of `editions/2`,
  each at its public address (`MishkaCmsCore.Runtime.Languages.url/3`):

      <a :for={edition <- @page_languages} href={edition.path} hreflang={edition.language}>
        {String.upcase(edition.language)}
      </a>

  An `href`, not a `<.link navigate>`: `<html lang dir>` is drawn once per HTTP response, so a live
  navigation into another language would keep the first one's.
  """

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageBuilder.ElementScopes
  alias MishkaCmsCore.Runtime.PageLanguageBackfill
  alias MishkaCmsCore.Runtime.PageProvision
  alias MishkaCmsCore.Runtime.Seo

  # What makes a translation a page of its own rather than a copy of its original: `translate/4`
  # sets each of these and takes everything else the create action accepts from the original.
  @own [:name, :path, :language, :language_group_id, :active, :site_id]

  # The builder's section for a page, which is what its element CSS row is named after.
  @section "page"

  # A translation starts as a copy of its page: the template is its page's, and its Elixir is still
  # stopped while the deployment's `:page_code` switch is off.
  @copy %{page_code: :copy}

  # What `indexable/1` reads of a page: what a URL is built from, and what decides it is listed.
  @indexed [
    :id,
    :path,
    :language,
    :language_group_id,
    :extra,
    :permissions,
    :seo_tags,
    :layout_id,
    :updated_at
  ]

  # A robots directive that keeps a URL out of an index. `none` is `noindex, nofollow` in one word.
  @unindexed ["noindex", "none"]

  @doc """
  The language a response is in: the captured `lang` when the page's path captures one, else the
  page's own language, else the primary language of `site_id` (`Languages.primary/1`).

  A page reached at `/blog` on a site that leaves its primary language unprefixed was matched as
  `/en/blog`, and captured `lang` as that language — see
  `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.resolve/2`.
  """
  @spec language(map(), map(), String.t() | nil) :: String.t()
  def language(page, captured, site_id) do
    case Languages.captures?(Map.get(page, :path)) and Map.get(captured, Languages.capture()) do
      language when is_binary(language) and language != "" -> language
      _not_captured -> Map.get(page, :language) || Languages.primary(site_id)
    end
  end

  @doc """
  The languages a page answers in, by the rule the resolver serves it by — what its hreflang links
  and a sitemap offer, so that neither names a URL that 404s.

  A page whose path captures `lang` answers every language of its site when it is marked as serving
  them all (`MishkaCmsCore.Runtime.PageProvision.serves_all_languages?/1`), and otherwise its own
  language alone, while the site still lists it — the capture admits nothing else (see
  `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState`). A page whose path captures none answers
  in its own language whatever the site lists: nothing in its URL is checked against them.

  `page` is a page row, or any map holding its `path`, `language` and `extra`.

      PageEditions.served_languages(%{path: "/:lang/about", language: "en", extra: %{}}, site.id)
      #=> ["en"]
  """
  @spec served_languages(map(), String.t() | nil) :: [String.t()]
  def served_languages(page, site_id) do
    case {Languages.captures?(Map.get(page, :path)), PageProvision.routing_language(page)} do
      {false, _routing} -> List.wrap(Map.get(page, :language))
      {true, nil} -> Languages.site(site_id)
      {true, language} -> if language in Languages.site(site_id), do: [language], else: []
    end
  end

  @doc """
  The public addresses a page answers at on its site, by the rule the resolver serves it by
  (`served_languages/2`) and in the form `MishkaCmsCore.Runtime.Languages.url/3` builds — what a
  sitemap lists and what no other page may answer.

  A literal page answers at its one address, and a page whose only capture is the language at one
  per language it answers. Any other pattern is the template of many addresses that only the
  component owning its rows can fill, and answers `[]`. `mode` builds them as the site would in that
  URL mode instead of its own.

      # site.languages ["en", "fa"], site.language_urls "prefix_others"
      PageEditions.urls(%{path: "/:lang/blog", language: "en", extra: %{"serves_all_languages" => true}}, site.id)
      #=> ["/blog", "/fa/blog"]
      PageEditions.urls(%{path: "/en/pricing", language: "en"}, site.id)
      #=> ["/pricing"]
  """
  @spec urls(map(), String.t() | nil) :: [String.t()]
  def urls(page, site_id), do: urls(page, site_id, Languages.url_mode(site_id))

  @spec urls(map(), String.t() | nil, String.t()) :: [String.t()]
  def urls(%{path: path} = page, site_id, mode) when is_binary(path) do
    captures =
      if language_only?(path),
        do: Enum.map(served_languages(page, site_id), &%{Languages.capture() => &1}),
        else: [%{}]

    for captured <- captures,
        url = Languages.url(path, captured, site_id, mode),
        is_binary(url),
        uniq: true,
        do: url
  end

  def urls(_page, _site_id, _mode), do: []

  @doc """
  The page and the other editions of its group, each as its stored path, its language and its
  `extra` — where `served_languages/2` reads whether it answers every language.

  `page` is the `:page` section of a compiled page's `__page_information__/0`, with the module's
  `extra` put beside it. One indexed read of the page's group, on the page's own site, and only the
  active editions: an inactive one is not served. Nothing in it depends on the request, so a page
  reads it once however often its captures change — see `alternates/3`.
  """
  @spec editions(map(), String.t() | nil) :: [
          %{language: String.t(), path: String.t(), extra: map() | nil}
        ]
  def editions(page, site_id) do
    current = Map.new([:path, :language, :extra], &{&1, Map.get(page, &1)})
    [current | siblings(page, site_id)]
  end

  @doc """
  Every language a page answers in, each at its URL, sorted by language — `[]` when there is only
  one, because a page with no other language has no alternate to offer.

  `editions` is `editions/2` of the page, `captured` what its pattern captured for this request.

  ## A pattern edition only speaks for the language segment

  Swapping `lang` in `/:lang/blog` — a page marked as serving every language — gives the Persian URL
  of that page, because every other segment is a literal that means the same thing in either
  language. An unmarked `/:lang/about` written in English is swapped into English alone
  (`served_languages/2`): the resolver refuses it `/fa/about`, which is its Persian edition's own
  row. Swapping it in `/:lang/blog/:slug` gives no Persian URL at all: the slug the visitor arrived
  with belongs to the edition they are LEAVING, and the Persian article has a slug of its own — so
  `/fa/blog/<english-slug>` is a URL that answers "that post is not published, or no longer exists".
  As an `<a>` it is a dead chip; as a `<link rel="alternate">` it tells a crawler the Persian version
  lives somewhere it does not.

  So a pattern edition is swapped into the languages it answers in (`served_languages/2`) only when
  `lang` is its ONLY capture. A page holding another one cannot know what that capture becomes in a
  different language — only the component that owns the row can, and that is where the translations
  row on a post or a document already comes from. Such a page still names ITSELF: the URL being
  served, under the language it is being served in, which is derivable and which hreflang wants in
  the set. On its own that is one edition and the list stays empty; beside a literal translation it
  is the half that makes the pair.
  """
  @spec alternates([map()], map(), String.t() | nil) :: [
          %{language: String.t(), path: String.t()}
        ]
  def alternates(editions, captured, site_id) do
    {patterns, literals} = Enum.split_with(editions, &Languages.captures?(&1.path))
    {swappable, opaque} = Enum.split_with(patterns, &language_only?(&1.path))

    literal_urls = Enum.map(literals, &{&1.language, Languages.url(&1.path, captured, site_id)})

    pattern_urls =
      for edition <- swappable,
          language <- served_languages(edition, site_id),
          swapped = Map.put(captured, Languages.capture(), language),
          do: {language, Languages.url(edition.path, swapped, site_id)}

    (literal_urls ++ pattern_urls ++ self_urls(opaque, captured, site_id))
    |> Enum.reject(fn {language, url} -> is_nil(url) or language in [nil, ""] end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {language, url} -> %{language: language, path: url} end)
    |> Enum.sort_by(& &1.language)
    |> case do
      [_, _ | _] = alternates -> alternates
      _one_or_none -> []
    end
  end

  # The URL a pattern is answering right now, under the language it was asked for. Nothing is guessed
  # here — every capture is the visitor's own — so it is safe for a pattern whose other captures are
  # not translatable.
  defp self_urls(editions, captured, site_id) do
    case Map.get(captured, Languages.capture()) do
      language when is_binary(language) and language != "" ->
        Enum.map(editions, &{language, Languages.url(&1.path, captured, site_id)})

      _not_captured ->
        []
    end
  end

  @doc """
  Whether a stored path's only capture is the language one — `/:lang/blog` yes, `/:lang/blog/:slug`
  and `/guides/:lang/*rest` no, and a literal path no. A glob is a capture like any other: `*rest`
  holds a path a translation spells its own way.

  Such a path makes one URL per language in `served_languages/2`, with `Languages.url/3` given
  only the language; any other pattern needs a capture only the component that owns its rows can
  fill.
  """
  @spec language_only?(String.t()) :: boolean()
  def language_only?(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.filter(&String.starts_with?(&1, [":", "*"]))
    |> case do
      [capture] -> capture in [":" <> Languages.capture(), "*" <> Languages.capture()]
      _none_or_several -> false
    end
  end

  defp siblings(%{language_group_id: group}, site_id)
       when is_binary(group) and is_binary(site_id) do
    Page
    |> Ash.Query.filter(language_group_id == ^group and active == true)
    |> Ash.Query.select([:path, :language, :extra])
    |> Ash.read(tenant: site_id, authorize?: false)
    |> case do
      {:ok, pages} -> Enum.map(pages, &Map.take(&1, [:path, :language, :extra]))
      {:error, _reason} -> []
    end
  end

  defp siblings(_page, _site_id), do: []

  @doc """
  The site's pages a search engine may be sent to — active, open to every visitor, not archived, and
  not asking to be left out of an index, sorted by path — and the literal paths of its other active
  pages.

  A login-only page is left out because a crawler is answered with the 404. A page is asking to be
  left out when the robots meta its head renders says `noindex` or `none`: its own, when its
  `seo_tags` hold one, else its layout's — a page's robots meta replaces its layout's in the head
  (`MishkaCmsWeb.RuntimeLive.page_head/1`), and the tags are read the way the head reads them. A
  page that holds no robots meta at all says what the head defaults to
  (`MishkaCmsCore.Runtime.Seo.noindex?/2`): a sign-in page, one whose `extra` holds `"visitors_only"`
  or an `"auth_role"`, is left out.

  The paths, as public addresses (`MishkaCmsCore.Runtime.Languages.url/3`), are what no sitemap may
  name: the resolver answers a literal page before any pattern, so `/fa/blog/archive` is the
  login-only page stored there, not `/:lang/blog/:slug` in Persian.

  One read of the site's active rows, as the system, with each page's `tenant_layout` loaded beside
  it. A page carries its `id`, `path`, `language`, `language_group_id`, `extra`, `permissions`,
  `seo_tags`, `layout_id` and `updated_at` and nothing else — its template stays in the database.
  """
  @spec indexable(String.t()) :: {[Page.t()], MapSet.t(String.t())}
  def indexable(site_id) when is_binary(site_id) do
    {listed, hidden} =
      Page
      |> Ash.Query.filter(active == true)
      |> Ash.Query.select(@indexed)
      |> Ash.Query.load(tenant_layout: Ash.Query.select(Layout, [:seo_tags]))
      |> Ash.Query.sort(:path)
      |> Ash.read!(tenant: site_id, authorize?: false, page: false)
      |> Enum.split_with(&(&1.permissions in [nil, []] and indexed?(&1)))

    {listed,
     hidden
     |> Enum.map(&Languages.url(&1.path, %{}, site_id))
     |> Enum.reject(&is_nil/1)
     |> MapSet.new()}
  end

  @doc """
  Whether a record a page shows may be listed in a sitemap, by the rule `indexable/1` holds a page
  to: it names no permission, and the robots meta of its own `seo_tags` does not say `noindex` or
  `none`. `parent` is what the record belongs to — a document for one of its pages: a permission of
  either keeps it out, and its robots meta counts when the record's own `seo_tags` hold none.

      listed?(%{permissions: [], seo_tags: []})                                #=> true
      listed?(%{permissions: ["members:read"], seo_tags: []})                  #=> false
      listed?(%{seo_tags: []}, %{seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"},
                                              content: "noindex"}]})           #=> false
  """
  @spec listed?(map(), map()) :: boolean()
  def listed?(record, parent \\ %{}) do
    Enum.all?([record, parent], &(Map.get(&1, :permissions) in [nil, []])) and
      robots(Map.get(record, :seo_tags), Map.get(parent, :seo_tags)) != :noindex
  end

  @doc """
  What the robots meta in `tags` says, read the way the head reads it: `:noindex` when a directive
  is `noindex` or `none`, `:index` when there is a robots meta that says neither, and `nil` when
  there is no robots meta, so whatever the page defaults to stands. `parent_tags` are read instead
  when `tags` hold none — a page's own robots meta replaces its layout's in the head.

      robots([%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex, follow"}]) #=> :noindex
      robots([%{tag: "meta", attrs: %{"name" => "robots"}, content: "index"}])           #=> :index
      robots([])                                                                         #=> nil
  """
  @spec robots(term(), term()) :: :index | :noindex | nil
  def robots(tags, parent_tags \\ []) do
    metas =
      case robot_metas(tags) do
        [] -> robot_metas(parent_tags)
        own -> own
      end

    cond do
      metas == [] -> nil
      metas |> Enum.concat() |> Enum.any?(&(&1 in @unindexed)) -> :noindex
      true -> :index
    end
  end

  # A page with a robots meta of its own, or its layout's, is indexed by what it says; one without
  # is by the head's default, which keeps a sign-in page out.
  defp indexed?(page) do
    case robots(page.seo_tags, layout_tags(page.tenant_layout)) do
      nil -> not Seo.noindex?([], page.extra)
      verdict -> verdict == :index
    end
  end

  defp layout_tags(%Layout{seo_tags: tags}), do: tags
  defp layout_tags(_no_layout), do: []

  # The directives of each robots meta in `tags`, one list per meta — an empty one still replaces the
  # layout's. A tag's keys are atoms or strings, and a meta's `content` stored beside `attrs` wins
  # over one inside them, as in the head.
  defp robot_metas(tags) do
    for %{} = tag <- List.wrap(tags),
        meta?(field(tag, :tag)),
        %{} = attrs <- [field(tag, :attrs)],
        robots?(attr(attrs, "name")),
        do: directives(field(tag, :content), attr(attrs, "content"))
  end

  defp meta?(tag), do: is_binary(tag) and String.downcase(tag) == "meta"

  defp robots?(name), do: is_binary(name) and String.downcase(String.trim(name)) == "robots"

  defp directives(beside, _inside) when is_binary(beside) and beside != "",
    do: directives_of(beside)

  defp directives(_beside, inside) when is_binary(inside), do: directives_of(inside)
  defp directives(_beside, _inside), do: []

  defp directives_of(content),
    do: content |> String.downcase() |> String.split([",", " "], trim: true)

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: value
    end)
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @doc """
  The languages of the page's site it has no edition in yet, in the site's order — what "Add
  translation" offers. An inactive edition counts: its row already holds the language. So does an
  archived one: one edition per language is checked among unarchived rows only, so a second edition
  made while the first is archived would refuse the first one's restore.
  """
  @spec untranslated(Page.t()) :: [String.t()]
  def untranslated(%Page{} = page) do
    taken = Enum.flat_map([:read, :archived], &languages_held(page, &1))

    Languages.site(page.site_id) -- [page.language | taken]
  end

  @doc """
  What "Add translation" offers as suggestions: `untranslated/1` first, then the languages this site's
  other pages are already written in.

  A SUGGESTION, NOT A RULE. The author types the code, exactly as the page form's own Language box
  takes one, and a code the site does not list is theirs to write — a literal path like `/de/about` is
  matched literally and answers whatever language it is written in. What `site.languages` decides is
  narrower: only a `lang` CAPTURE is held to that list, so a `/:lang/…` page cannot answer a language
  the site has not been given. The dialog says so beside the path rather than refusing the word.
  """
  @spec language_suggestions(Page.t()) :: [String.t()]
  def language_suggestions(%Page{} = page) do
    untranslated(page) ++ (languages_used(page) -- Languages.site(page.site_id))
  end

  defp languages_used(page) do
    taken = [page.language | Enum.flat_map([:read, :archived], &languages_held(page, &1))]

    Page
    |> Ash.Query.for_read(:read, %{}, tenant: page.site_id, authorize?: false)
    |> Ash.list!(:language, tenant: page.site_id, authorize?: false, uniq?: true)
    |> Enum.reject(&(is_nil(&1) or &1 in taken))
    |> Enum.sort()
  end

  defp languages_held(page, action) do
    Page
    |> Ash.Query.filter(language_group_id == ^group(page))
    |> Ash.Query.for_read(action, %{}, tenant: page.site_id, authorize?: false)
    |> Ash.list!(:language, tenant: page.site_id, authorize?: false, uniq?: true)
  end

  @doc """
  Where a translation of `page` into `language` lives, before the author says otherwise.

  The page's own path with its language swapped: a `lang` capture takes the new language, and so does
  a literal segment that names the page's language. A path with neither is prefixed.

      translation_path(%{path: "/about", language: "en"}, "fa")          #=> "/fa/about"
      translation_path(%{path: "/docs/en/intro", language: "en"}, "fa")  #=> "/docs/fa/intro"
      translation_path(%{path: "/:lang/post/:slug", language: "en"}, "fa") #=> "/fa/post/:slug"
  """
  @spec translation_path(map(), String.t()) :: String.t()
  def translation_path(%{path: path, language: from}, language) do
    segments = String.split(path, "/", trim: true)
    swapped = Enum.map(segments, &swap(&1, from, language))

    "/" <> Enum.join(if(swapped == segments, do: [language | segments], else: swapped), "/")
  end

  defp swap(segment, from, to) do
    if Languages.captures?("/" <> segment) or segment == from, do: to, else: segment
  end

  @doc """
  Creates `page` in `language` at `path`, as `actor`, through the page's own create action — so
  every rule a page is created under holds for a translation too.

  It starts as a copy of the page — every field the create action accepts, read from the action
  rather than listed here — under its own name, path and language, in the page's language group, and
  INACTIVE: until it is translated it is the original under another language's name, and nothing
  should serve that.

  The copy is the whole page because a part of one is a different page. Without its `permissions`
  the translation of a members-only page opens to everyone once activated; without its `helpers` a
  template calling them does not compile; without its `events` every `phx-click` it still sends is
  swallowed. Its code is written the way any page's is: by whoever may write the page, and refused
  while the deployment's `:page_code` switch is off.

  ITS ELEMENTS ARE ITS OWN. A translation is a page of its own and is edited in the builder as one,
  so it gets fresh element classes and its own copy of the original's element CSS — see
  `MishkaCmsCore.Runtime.PageBuilder.ElementScopes`, which says what a kept class costs. Every
  attribute it is copied from rather than the template alone, because a class is a class wherever
  the page is carrying it: `events`, `infos` and `seo_tags` are plain maps and their text is walked
  too. A helper is the one that is not — it is an embedded resource, and `ElementScopes.rewrite/2`
  says why a struct is left as written. Rewritten code stays trusted either way:
  `Changes.SignCode` signs these fields on the way in, so the translation's signatures are computed
  from the text it actually stores.
  """
  @spec translate(Page.t(), String.t(), String.t(), map()) :: {:ok, Page.t()} | {:error, term()}
  def translate(%Page{} = page, language, path, actor) do
    {copied, scopes} =
      Page
      |> Ash.Resource.Info.action(:create)
      |> Map.fetch!(:accept)
      |> Kernel.--(@own)
      |> then(&Map.take(page, &1))
      |> ElementScopes.rescope()

    copied
    |> Map.merge(%{
      name: "#{page.name}-#{language}",
      path: path,
      language: language,
      language_group_id: group(page),
      active: false
    })
    |> changeset(page.site_id, actor)
    |> Ash.Changeset.before_action(&join_group(&1, page))
    |> ElementScopes.carry_css(@section, page, scopes, actor)
    |> Ash.create()
  end

  defp changeset(attrs, site_id, %{site_id: nil} = actor) do
    Page
    |> Ash.Changeset.for_create(:master_create, Map.put(attrs, :site_id, site_id),
      actor: actor,
      context: @copy
    )
  end

  defp changeset(attrs, site_id, actor) do
    Page
    |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, actor: actor, context: @copy)
  end

  # A PAGE THE BOOT HAS NOT GROUPED — its backfill failed, or its row was written outside Ash — joins
  # the group its translation is given: its row's chips, and its hreflang links from its next compile
  # on, are read by its own group. A before-action, so a refused or failed create writes neither row.
  defp join_group(changeset, %Page{language_group_id: nil, id: id}) do
    case PageLanguageBackfill.run(id) do
      {:ok, _changed} -> changeset
      {:error, reason} -> Ash.Changeset.add_error(changeset, reason)
    end
  end

  defp join_group(changeset, _grouped), do: changeset

  defp group(%Page{language_group_id: nil, id: id}), do: id
  defp group(%Page{language_group_id: group}), do: group
end
