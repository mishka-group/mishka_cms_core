defmodule MishkaCmsCore.Runtime.Seo do
  @moduledoc """
  What a database page puts in `<head>` for search engines and link previews, the tags an editor
  can offer by name, and the variables a stored SEO value may use.

  `MishkaCmsWeb.RuntimeLive` resolves a page's head in `handle_params/3`: it hands the plugins on
  `event/0` the page's values, reads their answer with `accept/2`, and renders what `head/2`
  returns.

  ## What the page sets, and what a plugin fills

  A plugin on `event/0` answers with a page's defaults — what it reads off the record the page
  serves. Whatever the page itself sets wins, and whatever it leaves empty is the plugin's:

    * the title is a stored `title` tag, the page's over the layout's, else the plugin's `title`,
      else the page's own;
    * the description is the page's own, else the plugin's, else a stored `description` meta;
    * the image is a stored `og:image`, else the page's share card, else the plugin's;
    * the JSON-LD is the page's stored `schema` when it holds an object, else the plugin's, else one
      `WebPage`.

  ## What a page shows

  A page that serves one record per address — a post at `/:lang/blog/:slug` — says which kind in
  its `extra`, `"record" => "blog:post"` (`record_of/1`), and a plugin on `event/0` answers for the
  kinds it owns, whatever the page's path is. The kinds an editor can choose are what the installed
  extensions answer on `records_event/0` (`record_types/1`).

  The record's own `permissions` come back in the answer: `MishkaCmsWeb.RuntimeLive` opens the
  address only for whoever holds one of them, after the page's own, and the head keeps it out of an
  index.

  ## Share cards

  A public page whose head stores no `og:image` shows a share card, 1200×630, where a link to it is
  shared (`MishkaCmsCore.Runtime.ShareCard`): its title, description, the site's name and logo
  (`site_name/2`, the `site.logo` setting), and the plugin's `image` as its picture. A plugin adds what
  its record has to show through `card` — `eyebrow`, `people`, `byline`, `meta`, `picture` — and
  `card: false` keeps a page to the plugin's own image. Asked for only when `resolve/2` is given
  `card: true`; until it is drawn the head shows the plugin's image.

  The page's `<link rel="icon">` is the `site.favicon` setting, when it is set.

  ## Layers

  `head/2` stacks the tags. A later layer replaces any earlier tag with the same identity — the
  tag's name and every attribute except the one holding its value (`content` for a `meta` and a
  `title`, `href` for a `link`):

    1. the defaults, built from the resolved title, description, image, address and language, each
       only when it has a value — the entries of `catalog/0` marked `default?`;
    2. the `tags` a plugin on `event/0` returned;
    3. the layout's `seo_tags`;
    4. the page's `seo_tags`.

  What the page set itself is not undone by a plugin's tag: under a stored `title`, the plugin's
  `og:title` and `twitter:title` are left out; under the page's own description, its `description`,
  `og:description` and `twitter:description`; under a stored `og:image`, its `twitter:image` — so
  each follows the page, unless the layout or the page stores that tag too.

  `meta` and `link` tags render; a `title` tag is the title. An attribute name must be plain
  (`^[a-z][a-z0-9_:.-]*$`), an `on…` handler is dropped, and so is a value that is not a string, a
  number or a flag.

  ## Variables

  A string in the page's description, in a stored tag (layers 2–4) or anywhere inside the schema
  may name a variable as `{{key}}` or `{{ key }}`. `variables/0` lists the core ones; a plugin adds
  its own through `vars`, which win on the same key. The `page.*` ones hold the defaults, before
  the page's own title and description, so `{{page.title}}` in a stored `title` is the plugin's or
  the page's title. A description or a tag holding a placeholder that does not resolve is left out,
  a schema value that does not resolve is removed, and `{{` never reaches a visitor.

  ## Absolute addresses

  Every address the defaults emit is on the site's own address, with the scheme and port the
  endpoint answers on — the one the sitemap and robots.txt use (`base/1`,
  `MishkaCmsCore.Helpers.site_url/2`): `http://localhost:4000/en/about` in development,
  `https://example.com/en/about` in production. An `http://` or `https://` address stays as it is; a
  protocol-relative one, a `javascript:` one and anything else is left out rather than emitted
  (`absolute/2`). A stored `canonical`, `alternate`, `og:url`, `og:image` or `twitter:image` holding
  a `/…` path is written on the same base.

  ## Pages kept out of an index

  The default `robots` is `noindex, nofollow` for a page that names a permission or that is a
  sign-in page (`noindex?/2`), and for a record that names one; a stored `robots` tag replaces it as
  any other default.

  ## For an editor

  `catalog/0`, `variables/0` and `schema_types/0` describe what an editor offers. `stored_tags/1`,
  `stored_tag/3`, `stored_value/1`, `entry_of/1`, `tag_value/2`, `put_tag/2` and `drop_tag/2` read
  and write stored tags; `schema_object/3` and `schema_values/1` write and read one JSON-LD object;
  `resolve/2` is the head a page would render, which a preview draws.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.Runtime.{Languages, ShareCard}
  alias MishkaCmsCore.Runtime.States.TranslationsState
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.Hook

  @event "runtime:page:seo"
  @records_event "runtime:page:records"

  # Each tag the head reads, and the attribute that holds its value. A `title` is the title, not a
  # tag of its own.
  @value_attrs %{"meta" => "content", "link" => "href", "title" => "content"}

  # The tags whose value is an address: a `/…` path stored in one is written on the site's base.
  @addresses [
    {"link", "rel", "canonical"},
    {"link", "rel", "alternate"},
    {"meta", "property", "og:url"},
    {"meta", "property", "og:image"},
    {"meta", "name", "twitter:image"}
  ]

  @placeholder ~r/\{\{\s*([A-Za-z0-9_.:-]+)\s*\}\}/u
  @unresolved ~r/\{\{.*?\}\}/su

  @public_robots "index, follow, max-image-preview:large"
  @private_robots "noindex, nofollow"

  # What `head/2` reads for a key `seo` leaves out.
  @unset %{
    title: nil,
    description: nil,
    image: nil,
    type: "website",
    url: nil,
    language: nil,
    tags: [],
    schema: [],
    vars: %{},
    var_docs: [],
    permissions: [],
    site_id: nil,
    card: %{}
  }

  @texts [:title, :type, :language]
  @optional [:description, :image, :url]
  @lists [:tags, :schema, :var_docs]

  # What a page sets itself, and a plugin fills only when the page left it empty.
  @page_first [:description, :schema]

  @robots ~w(index noindex follow nofollow noarchive nosnippet noimageindex
             max-image-preview:none max-image-preview:standard max-image-preview:large)
  @og_types ~w(website article profile product book video.other)
  @twitter_cards ~w(summary summary_large_image)

  @type tag :: {String.t(), [{String.t(), String.t() | number() | boolean()}]}

  @type head :: %{
          title: String.t() | nil,
          description: String.t() | nil,
          image: String.t() | nil,
          url: String.t() | nil,
          card: map() | nil,
          tags: [tag()],
          schema: [String.t()],
          var_docs: [map()],
          permissions: [String.t()]
        }

  @doc """
  The event a page's SEO is resolved through, called once per `handle_params/3` with the map
  `MishkaCmsWeb.RuntimeLive` documents.
  """
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The event an extension names the kinds of record its pages show on. It is called with
  `%{site_id: id, records: []}`, and each plugin returns the map with its own appended to `records`:

    * `:id` — the kind, `"blog:post"`, which a page stores and its plugin on `event/0` answers for
    * `:group`, `:label` — what an editor lists it under and as, `"Blog"` and `"Post"`
    * `:captures` — the captures its address must have, `["slug"]`, `[]` for none
    * `:samples` — a few records to preview a page with,
      `[%{label: "A post", params: %{"slug" => "a-post"}}]`
  """
  @spec records_event() :: String.t()
  def records_event, do: @records_event

  @doc """
  The kinds of record the installed extensions offer for `site_id`, each as `records_event/0`
  describes, sorted by group; an entry without an `id`, a `group` and a `label` is left out.
  """
  @spec record_types(String.t() | nil) :: [map()]
  def record_types(site_id) do
    case Hook.call(@records_event, %{site_id: site_id, records: []}) do
      %{records: records} when is_list(records) ->
        records
        |> Enum.flat_map(&record_type/1)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{&1.group, &1.label})

      _not_answered ->
        []
    end
  end

  defp record_type(%{id: id, group: group, label: label} = type)
       when is_binary(id) and is_binary(group) and is_binary(label) do
    [
      %{
        id: id,
        group: group,
        label: label,
        captures:
          for(capture <- List.wrap(Map.get(type, :captures)), is_binary(capture), do: capture),
        samples:
          for(
            %{label: sample, params: %{} = params} <- List.wrap(Map.get(type, :samples)),
            is_binary(sample),
            do: %{label: sample, params: params}
          )
      }
    ]
  end

  defp record_type(_not_a_type), do: []

  @doc """
  The kind of record a page shows, from its `extra`: `"blog:post"`, `nil` for none.

      record_of(%{"record" => "blog:post"}) #=> "blog:post"
  """
  @spec record_of(term()) :: String.t() | nil
  def record_of(%{} = extra) when not is_struct(extra), do: presence(field(extra, :record))
  def record_of(_no_extra), do: nil

  @doc """
  The map `event/0` is called with for `page`, before any plugin has answered.

  `page` is the `:page` section of a compiled page's `__page_information__/0`, or any map holding
  its `title`, `language` and `seo` (`description`, `schema`). Options: `:site_id`, `:url` (the
  canonical address), `:params` (`@query_params`, `%{}` by default) and `:record`, the kind of
  record the page shows (`record_of/1`). An editor reads a dynamic page's `var_docs` by calling
  `event/0` with this map and no `:params`.
  """
  @spec given(map(), keyword()) :: map()
  def given(page, opts) do
    seo = Map.get(page, :seo) || %{}

    %{
      title: Map.get(page, :title),
      description: Map.get(seo, :description),
      image: nil,
      type: "website",
      url: Keyword.get(opts, :url),
      language: Map.get(page, :language),
      tags: [],
      schema: List.wrap(Map.get(seo, :schema)),
      vars: %{},
      var_docs: [],
      permissions: [],
      card: %{},
      page: page,
      site_id: Keyword.get(opts, :site_id),
      params: Keyword.get(opts, :params, %{}),
      record: Keyword.get(opts, :record)
    }
  end

  @doc """
  Every tag the head knows by name, in the order the head emits the defaults.

  Each entry:

    * `:id` — the identity's value: `"og:title"`, `"canonical"`
    * `:tag` and `:attrs` — the identity, as a stored tag writes it: `"meta"`,
      `%{"property" => "og:title"}`
    * `:value` — the attribute that holds the value: `"content"` for a meta, `"href"` for a link
    * `:needs` — other attributes the author fills: `["hreflang"]` for a language version
    * `:label`, `:help` — for an editor, in the current locale
    * `:default?` — whether the head emits it when nothing stored names it
    * `:values` — the allowed values of an enumerated tag, else `[]`
    * `:multiple?` — whether several `:values` combine, comma separated (`robots`)
    * `:default` — the value an editor fills in when the tag is added, which may name a variable
    * `:repeatable?` — whether a page holds several, one value each (`article:tag`)
  """
  @spec catalog() :: [map()]
  def catalog do
    [
      entry("title", "title", %{}, gettext("Title"),
        help:
          gettext(
            "The browser tab and the headline of a search result. Empty uses the record's title, else the page's."
          ),
        default: "{{page.title}}"
      ),
      entry("canonical", "link", %{"rel" => "canonical"}, gettext("Canonical address"),
        help:
          gettext("The one address search engines should index this page under. Absolute, https."),
        default: "{{page.url}}"
      ),
      entry("description", "meta", %{"name" => "description"}, gettext("Description"),
        help: gettext("The summary a search result shows under the title."),
        default: "{{page.description}}"
      ),
      entry("robots", "meta", %{"name" => "robots"}, gettext("Robots"),
        help:
          gettext(
            "Whether search engines may index this page and follow its links. A page that needs a permission is never indexed."
          ),
        values: @robots,
        multiple?: true,
        default: @public_robots
      ),
      entry("og:type", "meta", %{"property" => "og:type"}, gettext("Open Graph type"),
        help: gettext("What the page is to a link preview: a website, an article, a profile…"),
        values: @og_types,
        default: "website"
      ),
      entry("og:title", "meta", %{"property" => "og:title"}, gettext("Open Graph title"),
        help: gettext("The title a link preview shows."),
        default: "{{page.title}}"
      ),
      entry(
        "og:description",
        "meta",
        %{"property" => "og:description"},
        gettext("Open Graph description"),
        help: gettext("The text a link preview shows under its title."),
        default: "{{page.description}}"
      ),
      entry("og:url", "meta", %{"property" => "og:url"}, gettext("Open Graph address"),
        help: gettext("The address a link preview opens. Absolute, https."),
        default: "{{page.url}}"
      ),
      entry("og:site_name", "meta", %{"property" => "og:site_name"}, gettext("Site name"),
        help: gettext("The site a link preview names. The site title setting, unless set here."),
        default: "{{site.name}}"
      ),
      entry("og:locale", "meta", %{"property" => "og:locale"}, gettext("Locale"),
        help: gettext("The page's language, as en or pt_BR.")
      ),
      entry(
        "og:locale:alternate",
        "meta",
        %{"property" => "og:locale:alternate"},
        gettext("Other locales"),
        help: gettext("Each other language the page is published in, one tag each."),
        repeatable?: true
      ),
      entry("og:image", "meta", %{"property" => "og:image"}, gettext("Open Graph image"),
        help:
          gettext("The picture a link preview shows. An https address or a path on the site."),
        default: "{{page.image}}"
      ),
      entry("og:image:alt", "meta", %{"property" => "og:image:alt"}, gettext("Image text"),
        help: gettext("What the preview picture shows, for people who cannot see it."),
        default: "{{page.title}}"
      ),
      entry("twitter:card", "meta", %{"name" => "twitter:card"}, gettext("Twitter card"),
        help: gettext("How X (Twitter) draws a link preview: with a small or a large picture."),
        values: @twitter_cards,
        default: "summary_large_image"
      ),
      entry("twitter:title", "meta", %{"name" => "twitter:title"}, gettext("Twitter title"),
        help: gettext("The title an X (Twitter) preview shows."),
        default: "{{page.title}}"
      ),
      entry(
        "twitter:description",
        "meta",
        %{"name" => "twitter:description"},
        gettext("Twitter description"),
        help: gettext("The text an X (Twitter) preview shows."),
        default: "{{page.description}}"
      ),
      entry("twitter:image", "meta", %{"name" => "twitter:image"}, gettext("Twitter image"),
        help: gettext("The picture an X (Twitter) preview shows."),
        default: "{{page.image}}"
      ),
      entry(
        "twitter:image:alt",
        "meta",
        %{"name" => "twitter:image:alt"},
        gettext("Twitter image text"),
        help:
          gettext("What the X (Twitter) preview picture shows, for people who cannot see it."),
        default: "{{page.title}}"
      ),
      entry("icon", "link", %{"rel" => "icon"}, gettext("Favicon"),
        help:
          gettext(
            "The small picture a browser tab and a search result show for this page. The site's Favicon setting by default."
          )
      ),
      entry("alternate", "link", %{"rel" => "alternate"}, gettext("Language version"),
        help:
          gettext(
            "This page in another language, with its language code in hreflang, or x-default for the one to show when none matches."
          ),
        needs: ["hreflang"]
      ),
      entry("author", "meta", %{"name" => "author"}, gettext("Author"),
        help: gettext("Who wrote the page."),
        default?: false
      ),
      entry("twitter:site", "meta", %{"name" => "twitter:site"}, gettext("Site's X account"),
        help: gettext("The site's @username on X (Twitter)."),
        default?: false
      ),
      entry(
        "twitter:creator",
        "meta",
        %{"name" => "twitter:creator"},
        gettext("Author's X account"),
        help: gettext("The author's @username on X (Twitter)."),
        default?: false
      ),
      entry(
        "og:image:width",
        "meta",
        %{"property" => "og:image:width"},
        gettext("Image width"),
        help: gettext("In pixels, so a preview can be drawn before the picture loads."),
        default?: false,
        default: "1200"
      ),
      entry(
        "og:image:height",
        "meta",
        %{"property" => "og:image:height"},
        gettext("Image height"),
        help: gettext("In pixels, so a preview can be drawn before the picture loads."),
        default?: false,
        default: "630"
      ),
      entry(
        "og:image:type",
        "meta",
        %{"property" => "og:image:type"},
        gettext("Image type"),
        help: gettext("The picture's format, such as image/jpeg. A share card says it itself."),
        default?: false,
        default: "image/jpeg"
      ),
      entry(
        "article:published_time",
        "meta",
        %{"property" => "article:published_time"},
        gettext("Published"),
        help: gettext("When an article was first published, as an ISO 8601 date."),
        default?: false
      ),
      entry(
        "article:modified_time",
        "meta",
        %{"property" => "article:modified_time"},
        gettext("Modified"),
        help: gettext("When an article last changed, as an ISO 8601 date."),
        default?: false
      ),
      entry(
        "article:author",
        "meta",
        %{"property" => "article:author"},
        gettext("Article author"),
        help: gettext("The address of the author's profile."),
        default?: false
      ),
      entry(
        "article:section",
        "meta",
        %{"property" => "article:section"},
        gettext("Article section"),
        help: gettext("The section an article belongs to, such as Technology."),
        default?: false
      ),
      entry("article:tag", "meta", %{"property" => "article:tag"}, gettext("Article tag"),
        help: gettext("A word an article is about, one tag each."),
        default?: false,
        repeatable?: true
      )
    ]
  end

  @doc """
  The variables every page fills, each `%{key:, label:, help:}` for an editor, in the current
  locale. A stored value names one as `{{page.title}}`.

  A dynamic page's own variables come from its plugin on `event/0`: it returns their values in
  `vars` and describes them in `var_docs`, `[%{key: "post.title", label: "Post title"}]`.
  """
  @spec variables() :: [%{key: String.t(), label: String.t(), help: String.t()}]
  def variables do
    [
      %{
        key: "page.title",
        label: gettext("Page title"),
        help: gettext("The title this address shows.")
      },
      %{
        key: "page.description",
        label: gettext("Page description"),
        help: gettext("The page's description. Empty leaves out whatever uses it.")
      },
      %{
        key: "page.url",
        label: gettext("Page address"),
        help: gettext("The canonical address of this page, with https.")
      },
      %{
        key: "page.language",
        label: gettext("Page language"),
        help: gettext("The language code of this address, such as en.")
      },
      %{
        key: "page.image",
        label: gettext("Page image"),
        help:
          gettext("The picture a plugin set for this address. Empty leaves out whatever uses it.")
      },
      %{
        key: "site.name",
        label: gettext("Site name"),
        help: gettext("The site title setting, in the page's language when Translations has it.")
      },
      %{
        key: "site.url",
        label: gettext("Site address"),
        help: gettext("The site's https address, with no path.")
      }
    ]
  end

  @doc """
  The JSON-LD types an editor offers beside the automatic `WebPage`, each with the few fields
  search engines read, in the current locale.

  Each entry:

    * `:type` — the `@type`, `"Article"`
    * `:label` — for an editor
    * `:fields` — `[%{key:, label:, default:}]`; `default` is the value an editor fills in, which
      may name a variable. A key with a dot, `"author.name"`, is a value of a nested object
    * `:nested` — the `@type` of each nested object, by its key: `%{"author" => "Person"}`
    * `:faq?` — whether the object holds questions and answers instead of fields (`FAQPage`)
    * `:stars?` — whether search engines may show its rating as stars: a review snippet is offered
      for a product, a recipe, a course, a book, an application, an event and a local business,
      never for an article or a blog post
  """
  @spec schema_types() :: [map()]
  def schema_types do
    title = schema_field("headline", gettext("Headline"), "{{page.title}}")
    name = schema_field("name", gettext("Name"), "{{page.title}}")
    site_name = schema_field("name", gettext("Name"), "{{site.name}}")
    description = schema_field("description", gettext("Description"), "{{page.description}}")
    image = schema_field("image", gettext("Image"), "{{page.image}}")
    published = schema_field("datePublished", gettext("Published"), "")
    author = schema_field("author.name", gettext("Author"), "{{site.name}}")

    rating = [
      schema_field("aggregateRating.ratingValue", gettext("Rating (out of 5)"), ""),
      schema_field("aggregateRating.ratingCount", gettext("Number of ratings"), "")
    ]

    price = [
      schema_field("offers.price", gettext("Price"), ""),
      schema_field("offers.priceCurrency", gettext("Currency"), "")
    ]

    rated = %{"aggregateRating" => "AggregateRating"}

    [
      schema_type("Article", gettext("Article"), [title, description, image, published, author],
        nested: %{"author" => "Person"}
      ),
      schema_type(
        "BlogPosting",
        gettext("Blog post"),
        [title, description, image, published, author],
        nested: %{"author" => "Person"}
      ),
      schema_type("FAQPage", gettext("Questions and answers"), [], faq?: true),
      schema_type(
        "Product",
        gettext("Product"),
        [name, description, image, schema_field("brand.name", gettext("Brand"), "")] ++
          price ++ rating,
        nested: Map.merge(rated, %{"brand" => "Brand", "offers" => "Offer"}),
        stars?: true
      ),
      schema_type(
        "Recipe",
        gettext("Recipe"),
        [
          name,
          description,
          image,
          author,
          schema_field("totalTime", gettext("Total time (PT45M)"), ""),
          schema_field("recipeYield", gettext("Serves"), "")
        ] ++ rating,
        nested: Map.put(rated, "author", "Person"),
        stars?: true
      ),
      schema_type(
        "Course",
        gettext("Course"),
        [name, description, schema_field("provider.name", gettext("Taught by"), "{{site.name}}")] ++
          rating,
        nested: Map.put(rated, "provider", "Organization"),
        stars?: true
      ),
      schema_type(
        "Book",
        gettext("Book"),
        [name, description, image, author, schema_field("isbn", gettext("ISBN"), "")] ++ rating,
        nested: Map.put(rated, "author", "Person"),
        stars?: true
      ),
      schema_type(
        "SoftwareApplication",
        gettext("Application"),
        [
          name,
          description,
          schema_field("applicationCategory", gettext("Category"), ""),
          schema_field("operatingSystem", gettext("Runs on"), "")
        ] ++ price ++ rating,
        nested: Map.put(rated, "offers", "Offer"),
        stars?: true
      ),
      schema_type(
        "VideoObject",
        gettext("Video"),
        [
          name,
          description,
          schema_field("thumbnailUrl", gettext("Thumbnail"), "{{page.image}}"),
          schema_field("uploadDate", gettext("Uploaded"), ""),
          schema_field("contentUrl", gettext("Video address"), ""),
          schema_field("duration", gettext("Length (PT2M30S)"), "")
        ]
      ),
      schema_type(
        "Event",
        gettext("Event"),
        [
          name,
          description,
          image,
          schema_field("startDate", gettext("Starts"), ""),
          schema_field("location.name", gettext("Place"), "")
        ] ++ rating,
        nested: Map.put(rated, "location", "Place"),
        stars?: true
      ),
      schema_type("Organization", gettext("Organization"), [
        site_name,
        schema_field("url", gettext("Address"), "{{site.url}}"),
        schema_field("logo", gettext("Logo"), "{{page.image}}"),
        description
      ]),
      schema_type(
        "LocalBusiness",
        gettext("Local business"),
        [
          site_name,
          schema_field("url", gettext("Address"), "{{site.url}}"),
          image,
          schema_field("telephone", gettext("Telephone"), ""),
          schema_field("address.streetAddress", gettext("Street"), ""),
          schema_field("address.addressLocality", gettext("City"), "")
        ] ++ rating,
        nested: Map.put(rated, "address", "PostalAddress"),
        stars?: true
      ),
      schema_type("Person", gettext("Person"), [
        name,
        schema_field("url", gettext("Address"), "{{page.url}}"),
        image,
        schema_field("jobTitle", gettext("Job title"), ""),
        description
      ])
    ]
  end

  @doc """
  The JSON-LD object of `type`, one of `schema_types/0`, with an editor's `values` written over
  `object`: each field keyed as `schema_types/0` names it, a blank value removing it, and every other
  key of `object` kept. A `FAQPage` reads `"questions"`, `[%{"question" => …, "answer" => …}]`, and
  leaves out a pair with no question. `nil` for a type `schema_types/0` does not name.

      schema_object("Article", %{"headline" => "{{page.title}}", "author.name" => "Ada"})
      #=> %{"@context" => "https://schema.org", "@type" => "Article",
      #     "headline" => "{{page.title}}", "author" => %{"@type" => "Person", "name" => "Ada"}}
  """
  @spec schema_object(String.t(), map(), map()) :: map() | nil
  def schema_object(type, values, object \\ %{}) when is_map(values) and is_map(object) do
    root = Map.merge(object, schema_root(type))

    case Enum.find(schema_types(), &(&1.type == type)) do
      nil -> nil
      %{faq?: true} -> faq_object(root, values)
      known -> Enum.reduce(known.fields, root, &put_field(&2, &1.key, values, known))
    end
  end

  @doc """
  Stored tags in one shape, `%{tag:, attrs:, content:}` with string attribute names, whichever keys
  they were stored with. Anything that is not a map is left out; a tag the head will not render is
  kept, so writing the list back loses nothing.
  """
  @spec stored_tags(term()) :: [%{tag: term(), attrs: map(), content: term()}]
  def stored_tags(tags) do
    for %{} = tag <- List.wrap(tags), not is_struct(tag) do
      attrs =
        case field(tag, :attrs) do
          %{} = attrs -> Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
          _no_attrs -> %{}
        end

      %{tag: field(tag, :tag), attrs: attrs, content: field(tag, :content)}
    end
  end

  @doc """
  A stored tag for `tag` with `attrs` holding `value`: a meta's in `content`, a link's in its `href`.

      stored_tag("meta", %{"property" => "og:image"}, "/a.png")
      #=> %{tag: "meta", attrs: %{"property" => "og:image"}, content: "/a.png"}
  """
  @spec stored_tag(String.t(), map(), String.t()) :: map()
  def stored_tag("link", attrs, value),
    do: %{tag: "link", attrs: Map.put(attrs, "href", value), content: nil}

  def stored_tag(tag, attrs, value), do: %{tag: tag, attrs: attrs, content: value}

  @doc """
  The value of the first of `tags` (`stored_tags/1`) the catalog entry `id` names, `nil` for none.
  """
  @spec tag_value([map()], String.t()) :: String.t() | nil
  def tag_value(tags, id) do
    case Enum.find(catalog(), &(&1.id == id)) do
      nil -> nil
      entry -> Enum.find_value(tags, &(names?(entry, &1) && stored_value(&1)))
    end
  end

  @doc """
  The catalog entry a stored tag is, `nil` for one the catalog does not name.
  """
  @spec entry_of(map()) :: map() | nil
  def entry_of(tag), do: Enum.find(catalog(), &names?(&1, tag))

  @doc """
  The value a stored tag holds: a meta's `content`, a link's `href`.
  """
  @spec stored_value(map()) :: String.t() | nil
  def stored_value(%{tag: "link", attrs: attrs}), do: presence(Map.get(attrs, "href"))

  def stored_value(%{attrs: attrs} = tag),
    do: presence(Map.get(tag, :content)) || presence(Map.get(attrs, "content"))

  @doc """
  `tags` with `tag` written in place of the first one with its identity — its name and attributes
  but its value — or after them when there is none. A repeatable catalog entry (`article:tag`) is
  always written after them.
  """
  @spec put_tag([map()], map()) :: [map()]
  def put_tag(tags, tag) do
    index = Enum.find_index(tags, &(identity_of(&1) == identity_of(tag)))

    case {index, entry_of(tag)} do
      {nil, _entry} -> tags ++ [tag]
      {_index, %{repeatable?: true}} -> tags ++ [tag]
      {index, _entry} -> List.replace_at(tags, index, tag)
    end
  end

  @doc """
  `tags` without any the catalog entry `id` names.
  """
  @spec drop_tag([map()], String.t()) :: [map()]
  def drop_tag(tags, id) do
    case Enum.find(catalog(), &(&1.id == id)) do
      nil -> tags
      entry -> Enum.reject(tags, &names?(entry, &1))
    end
  end

  @doc """
  An editor's values for a stored JSON-LD object: `{type, values}` when its `@type` is one of
  `schema_types/0`, keyed as `schema_object/2` reads them; `nil` for any other object.
  """
  @spec schema_values(term()) :: {String.t(), map()} | nil
  def schema_values(%{"@type" => type} = object) do
    case Enum.find(schema_types(), &(&1.type == type)) do
      nil -> nil
      %{faq?: true} -> {type, %{"questions" => questions(object)}}
      known -> {type, Map.new(known.fields, &{&1.key, field_text(object, &1.key)})}
    end
  end

  def schema_values(_not_a_typed_object), do: nil

  @doc """
  A site's own address with no path, on the scheme and port the endpoint answers on — the base the
  sitemap and robots.txt use (`MishkaCmsCore.Helpers.site_url/2`); `nil` for no host.

      base("blog.example.com") #=> "https://blog.example.com" in production
      base("localhost")        #=> "http://localhost:4000" in development
  """
  @spec base(String.t() | nil) :: String.t() | nil
  def base(host) when is_binary(host) and host != "", do: Helpers.site_url(host, "")
  def base(_no_host), do: nil

  @doc """
  An `http://…` or `https://…` address as it is, a `/…` path on `base`, `nil` for anything else —
  a protocol-relative address, a `javascript:` one, a relative path.

      absolute("/en/about", "https://example.com") #=> "https://example.com/en/about"
      absolute("//cdn.example.com/a.png", "https://example.com") #=> nil
  """
  @spec absolute(term(), String.t() | nil) :: String.t() | nil
  def absolute("https://" <> rest = url, _base) when rest != "", do: url
  def absolute("http://" <> rest = url, _base) when rest != "", do: url
  def absolute("//" <> _protocol_relative, _base), do: nil
  def absolute("/" <> _ = path, base) when is_binary(base), do: base <> path
  def absolute(_not_an_address, _base), do: nil

  @doc """
  Whether a page is kept out of an index unless a stored `robots` tag says otherwise: it names a
  permission, or its `extra` marks it as a sign-in page — `"visitors_only"` or an `"auth_role"`, as
  `MishkaCmsCore.Install.StarterContent` writes them. Pass `head/2` the answer as `:restricted?`.

      noindex?([], %{"auth_role" => "sign_in"}) #=> true
      noindex?(["members:read"], nil)           #=> true
      noindex?([], %{})                         #=> false
  """
  @spec noindex?(term(), term()) :: boolean()
  def noindex?(permissions, extra), do: permissions not in [nil, []] or sign_in?(extra)

  @doc """
  A language code as Open Graph writes a locale, `ll_RR`: its language and the two-letter region
  the code names, else the one CLDR's likely subtags give the language; the language alone when
  CLDR gives none, or only a numeric region. `nil` for what is no language code.

      locale("pt-br")  #=> "pt_BR"
      locale("en")     #=> "en_US"
      locale("fa")     #=> "fa_IR"
      locale("es-419") #=> "es"
  """
  @spec locale(String.t() | nil) :: String.t() | nil
  def locale(language) when is_binary(language) do
    case Localize.validate_locale(language) do
      {:ok, %{language: code} = tag} when is_atom(code) and not is_nil(code) ->
        og_locale(Atom.to_string(code), tag.territory)

      _no_code ->
        nil
    end
  end

  def locale(_no_language), do: nil

  defp og_locale(code, territory) when is_atom(territory) and not is_nil(territory) do
    case Atom.to_string(territory) do
      <<a, b>> = region when a in ?A..?Z and b in ?A..?Z -> code <> "_" <> region
      _numeric -> code
    end
  end

  defp og_locale(code, _no_territory), do: code

  @doc """
  The head `page` renders at one address: `given/2`, then the plugins on `event/0`, `accept/2` and
  `head/2`. `MishkaCmsWeb.RuntimeLive` calls it for every address it serves; an editor's preview
  calls it with no `:params`, and reads the plugin's variables from `var_docs`.

  Options: `:site_id`, `:url` and `:params` as `given/2` takes them; `:base`, `:languages`,
  `:restricted?` and `:layers` as `head/2` takes them; and `:stand_ins` — `true` for an editor's
  preview, where a page that serves records has none to read: each variable a plugin describes in
  `var_docs` but did not fill reads as `{key}`, `{post.title}`, so the preview shows where it goes.
  """
  @spec resolve(map(), keyword()) :: head()
  def resolve(page, opts) do
    given = given(page, Keyword.take(opts, [:site_id, :url, :params, :record]))

    event()
    |> Hook.call(given)
    |> accept(given)
    |> stand_ins(Keyword.get(opts, :stand_ins, false))
    |> head(
      opts
      |> Keyword.take([:base, :languages, :restricted?, :layers, :card])
      |> Keyword.put(:page_description?, set?(given.description))
      |> Keyword.put(:page_number, page_number(given.params))
    )
  end

  @doc """
  The number of the page of a list an address asks for, `?page=2`; `nil` for the first and for an
  address that asks for none.
  """
  @spec page_number(term()) :: pos_integer() | nil
  def page_number(%{"page" => page}) when is_binary(page) do
    case Integer.parse(page) do
      {number, ""} when number > 1 -> number
      _first_or_not_a_number -> nil
    end
  end

  def page_number(_params), do: nil

  defp stand_ins(seo, true) do
    shown = for %{key: key} when is_binary(key) <- seo.var_docs, into: %{}, do: {key, "{#{key}}"}
    %{seo | vars: Map.merge(shown, seo.vars)}
  end

  defp stand_ins(seo, false), do: seo

  @doc """
  The map a plugin on `event/0` returned, read against the one it was given. Each key keeps the
  plugin's value when it has the right type and the given one otherwise; `page`, `site_id`,
  `params` and `record` are always the given ones. Anything but a map is the given map.

  The page's own `description` and `schema` win: the plugin's fill them only when the page's are
  empty.

    * `title`, `type`, `language` — a non-empty string
    * `description`, `image`, `url` — a string or `nil`
    * `tags`, `schema`, `var_docs` — a list
    * `vars` — a map
    * `permissions` — a list; what in it is not a string is dropped
  """
  @spec accept(term(), map()) :: map()
  def accept(%{} = returned, given) when not is_struct(returned),
    do: Map.new(given, fn {key, value} -> {key, answer(key, Map.fetch(returned, key), value)} end)

  def accept(_not_a_map, given), do: given

  defp answer(key, returned, given) when key in @page_first do
    if set?(given), do: given, else: accepted(key, returned, given)
  end

  defp answer(key, returned, given), do: accepted(key, returned, given)

  defp set?(value) when is_binary(value), do: is_binary(presence(value))
  defp set?(value) when is_list(value), do: value != []
  defp set?(_unset), do: false

  defp accepted(key, {:ok, value}, _given)
       when key in @texts and is_binary(value) and value != "",
       do: value

  defp accepted(key, {:ok, value}, _given)
       when key in @optional and (is_binary(value) or is_nil(value)),
       do: value

  defp accepted(key, {:ok, value}, _given) when key in @lists and is_list(value), do: value

  defp accepted(:permissions, {:ok, value}, _given) when is_list(value),
    do: Enum.filter(value, &is_binary/1)

  defp accepted(:vars, {:ok, %{} = value}, _given) when not is_struct(value), do: value
  defp accepted(:card, {:ok, %{} = value}, _given) when not is_struct(value), do: value
  defp accepted(:card, {:ok, false}, _given), do: false
  defp accepted(_key, _returned, given), do: given

  @doc """
  The head of a page, from the map `accept/2` returned.

  `seo` holds `title`, `description`, `image`, `type`, `url`, `language`, `tags`, `schema`, `vars`,
  `permissions` and `site_id`. Options:

    * `:base` — `base/1` of the site's host
    * `:languages` — the page's editions, `[%{language:, path:}]`, `[]` when it has one
    * `:restricted?` — whether the page is kept out of an index, `noindex?/2`; a record that names
      `permissions` is kept out too
    * `:layers` — the layout's and the page's stored `seo_tags`, in that order
    * `:page_description?` — whether `description` is the page's own rather than a plugin's
    * `:page_number` — the page of a list this address shows (`page_number/1`); past the first,
      the title says so, `Blog – Page 2`, so no two pages of a list share one
    * `:card` — whether a page with no stored `og:image` shows its share card (`ShareCard.image/2`),
      `false` by default: a preview asks for none; `:spec` returns what the card would show in
      `card` without asking for it

  A stored `title` replaces `title`, and a stored `og:image` replaces `image`, else the share card
  does once it is drawn. The `description` has its variables filled; empty, or naming one that does
  not resolve, a stored `description` meta stands in.

  Returns the resolved `title`, `description`, `image` and `url`, the share `card`'s spec (with
  `:card`), the `tags` to render as
  `{name, attributes}`, the `schema` as JSON strings safe inside `<script>`, and the `var_docs` and
  `permissions` a plugin answered.
  """
  @spec head(map(), keyword()) :: head()
  def head(seo, opts) do
    seo = Map.merge(@unset, seo)

    opts =
      Keyword.update(opts, :restricted?, seo.permissions != [], &(&1 or seo.permissions != []))

    base = Keyword.get(opts, :base)
    site_title = site_name(seo.site_id, seo.language)
    url = absolute(seo.url, base)
    layers = [seo.tags | Keyword.get(opts, :layers, [])]

    # `{{page.image}}` and `{{page.description}}` read the defaults: the plugin's image, else a
    # stored og:image, and the description, else a stored description meta.
    unfilled = layers |> Enum.map(&tags/1) |> stack()

    core =
      fill_vars(
        seo,
        %{
          url: url,
          image:
            absolute(seo.image, base) ||
              absolute(meta_value(unfilled, "property", "og:image"), base)
        },
        site_title,
        base
      )

    description =
      filled_text(seo.description, core) ||
        filled_text(meta_value(unfilled, "name", "description"), core)

    vars = if description, do: Map.put(core, "page.description", description), else: core
    [plugin | own] = Enum.map(layers, &(&1 |> fill_tags(vars) |> tags()))
    owned = owned(stack(own), Keyword.get(opts, :page_description?, false))
    stored = stack([Enum.reject(plugin, &MapSet.member?(owned, identity(&1))) | own])

    description = description || meta_value(stored, "name", "description")
    stored_image = absolute(meta_value(stored, "property", "og:image"), base)

    {spec, card} =
      if stored_image, do: {nil, nil}, else: share_card(seo, description, site_title, base, opts)

    resolved =
      Map.put(
        %{
          seo
          | title: numbered(title_value(stored) || seo.title, Keyword.get(opts, :page_number)),
            description: description,
            image:
              stored_image || (card && absolute(card.url, base)) || absolute(seo.image, base),
            url: url
        },
        :share_card,
        card
      )

    %{
      title: resolved.title,
      description: resolved.description,
      image: resolved.image,
      url: url,
      card: spec,
      tags:
        [tags(defaults(resolved, site_title, base, opts)), stored]
        |> stack()
        |> Enum.reject(&match?({"title", _attrs}, &1))
        |> Enum.map(&absolute_tag(&1, base)),
      schema: resolved |> schema(vars, site_title, base) |> Enum.flat_map(&json_ld/1),
      var_docs: List.wrap(seo.var_docs),
      permissions: seo.permissions
    }
  end

  defp schema_field(key, label, default), do: %{key: key, label: label, default: default}

  defp schema_type(type, label, fields, opts \\ []) do
    %{
      type: type,
      label: label,
      fields: fields,
      nested: Keyword.get(opts, :nested, %{}),
      faq?: Keyword.get(opts, :faq?, false),
      stars?: Keyword.get(opts, :stars?, false)
    }
  end

  defp schema_root(type), do: %{"@context" => "https://schema.org", "@type" => type}

  defp put_field(object, key, values, known) do
    value = values |> Map.get(key) |> presence()

    case {String.split(key, ".", parts: 2), value} do
      {[key], nil} ->
        Map.delete(object, key)

      {[key], value} ->
        Map.put(object, key, value)

      {[parent, child], value} ->
        nested =
          case Map.get(object, parent) do
            %{} = nested -> nested
            _none -> %{"@type" => Map.get(known.nested, parent)}
          end

        nested = if value, do: Map.put(nested, child, value), else: Map.delete(nested, child)

        if Map.keys(nested) -- ["@type"] == [],
          do: Map.delete(object, parent),
          else: Map.put(object, parent, nested)
    end
  end

  defp names?(entry, %{tag: tag, attrs: attrs}) when is_binary(tag),
    do:
      String.downcase(tag) == entry.tag and
        Enum.all?(entry.attrs, fn {key, value} -> Map.get(attrs, key) == value end)

  defp names?(_entry, _not_a_tag), do: false

  defp identity_of(%{tag: tag, attrs: attrs}) when is_binary(tag) do
    tag = String.downcase(tag)
    {tag, Map.delete(attrs, Map.get(@value_attrs, tag, "content"))}
  end

  defp identity_of(tag), do: tag

  defp field_text(object, key), do: object |> dig(String.split(key, ".")) |> text_of()

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)
  defp dig(_not_a_map, _keys), do: nil

  defp faq_object(root, values) do
    pairs =
      for %{} = pair <- values |> Map.get("questions") |> List.wrap(),
          is_binary(presence(Map.get(pair, "question"))),
          do: %{
            "@type" => "Question",
            "name" => Map.get(pair, "question"),
            "acceptedAnswer" => %{"@type" => "Answer", "text" => text_of(Map.get(pair, "answer"))}
          }

    Map.put(root, "mainEntity", pairs)
  end

  defp questions(object) do
    for %{} = question <- object |> Map.get("mainEntity") |> List.wrap(),
        do: %{
          "question" => text_of(Map.get(question, "name")),
          "answer" => question |> dig(["acceptedAnswer", "text"]) |> text_of()
        }
  end

  defp text_of(value) when is_binary(value), do: value
  defp text_of(value) when is_number(value), do: to_string(value)
  defp text_of(_no_text), do: ""

  defp sign_in?(%{} = extra) when not is_struct(extra),
    do: field(extra, :visitors_only) == true or is_binary(presence(field(extra, :auth_role)))

  defp sign_in?(_no_extra), do: false

  defp entry(id, tag, attrs, label, opts) do
    %{
      id: id,
      tag: tag,
      attrs: attrs,
      value: Map.fetch!(@value_attrs, tag),
      needs: Keyword.get(opts, :needs, []),
      label: label,
      help: Keyword.fetch!(opts, :help),
      default?: Keyword.get(opts, :default?, true),
      values: Keyword.get(opts, :values, []),
      multiple?: Keyword.get(opts, :multiple?, false),
      default: Keyword.get(opts, :default, ""),
      repeatable?: Keyword.get(opts, :repeatable?, false)
    }
  end

  defp defaults(seo, site_title, base, opts) do
    languages = Keyword.get(opts, :languages, [])
    robots = if Keyword.get(opts, :restricted?, false), do: @private_robots, else: @public_robots
    others = for %{language: language} <- languages, language != seo.language, do: language
    %{title: title, description: description, image: image, url: url} = seo

    List.flatten([
      link(%{"rel" => "canonical"}, url),
      meta("name", "description", description),
      meta("name", "robots", robots),
      meta("property", "og:type", seo.type),
      meta("property", "og:title", title),
      meta("property", "og:description", description),
      meta("property", "og:url", url),
      meta("property", "og:site_name", site_title),
      meta("property", "og:locale", locale(seo.language)),
      Enum.map(others, &meta("property", "og:locale:alternate", locale(&1))),
      meta("property", "og:image", image),
      card_size(seo[:share_card]),
      meta("property", "og:image:alt", image && title),
      meta("name", "twitter:card", if(image, do: "summary_large_image", else: "summary")),
      meta("name", "twitter:title", title),
      meta("name", "twitter:description", description),
      meta("name", "twitter:image", image),
      meta("name", "twitter:image:alt", image && title),
      link(%{"rel" => "icon"}, absolute(Settings.get("site.favicon", nil, seo.site_id), base)),
      alternate_links(languages, base, seo.site_id)
    ])
  end

  defp meta(key, name, value) when is_binary(value) and value != "",
    do: [%{tag: "meta", attrs: %{key => name, "content" => value}}]

  defp meta(_key, _name, _no_value), do: []

  defp card_size(%{width: width, height: height, type: type}),
    do: [
      meta("property", "og:image:width", Integer.to_string(width)),
      meta("property", "og:image:height", Integer.to_string(height)),
      meta("property", "og:image:type", type)
    ]

  defp card_size(_no_card), do: []

  # What the share card of a public page shows — from what the head resolved and what the plugin
  # added — and the card itself once drawn (`card: true` asks for it); `{nil, nil}` for a page kept
  # out of an index, and when nobody asked.
  defp share_card(seo, description, site_title, base, opts) do
    with mode when mode in [true, :spec] <- Keyword.get(opts, :card, false),
         false <- Keyword.get(opts, :restricted?, false),
         %{} = card <- seo.card,
         %URI{host: host} when is_binary(host) <- base && URI.parse(base) do
      spec =
        Map.merge(
          %{
            title: seo.title,
            description: description,
            site: site_title,
            host: host,
            logo: Settings.get("site.logo", nil, seo.site_id),
            picture: seo.image
          },
          card
        )

      {spec, mode == true && ShareCard.image(seo.site_id, spec)}
    else
      _no_card -> {nil, nil}
    end
  end

  @doc """
  The site's name in `language`: the `site.title` setting, translated when the site's Translations
  hold that title in `language` (`MishkaCmsCore.Runtime.States.TranslationsState`), `nil` when the
  setting is empty.

      site_name(site_id, "fa") #=> "میشکا"
  """
  @spec site_name(String.t() | nil, String.t() | nil) :: String.t() | nil
  def site_name(site_id, language) do
    case presence(Settings.get("site.title", nil, site_id)) do
      title when is_binary(title) and is_binary(language) ->
        presence(TranslationsState.lookup(site_id, language, title)) || title

      title ->
        title
    end
  end

  defp link(attrs, href) when is_binary(href) and href != "",
    do: [%{tag: "link", attrs: Map.put(attrs, "href", href)}]

  defp link(_attrs, _no_href), do: []

  @doc """
  The `rel="alternate"` links of a page in several languages: one per edition, at its absolute
  address (`absolute/2`), and one `hreflang="x-default"` at the edition in the site's primary
  language (`MishkaCmsCore.Runtime.Languages.primary/1`), when there is one. `[]` for fewer than two
  editions, which have no alternate to offer.

  `editions` is `[%{language: language, path: path}]`, each `path` a public address —
  `MishkaCmsCore.Runtime.Languages.url/3`'s. The head's own are `:languages` of `head/2`; a plugin
  answering for a record puts the record's in its `tags` from here.

      Seo.alternate_links([%{language: "en", path: "/about"}, %{language: "fa", path: "/fa/about"}],
        "https://acme.test", site.id)
      #=> [%{tag: "link", attrs: %{"rel" => "alternate", "hreflang" => "en", "href" => "https://acme.test/about"}},
      #    %{tag: "link", attrs: %{"rel" => "alternate", "hreflang" => "fa", "href" => "https://acme.test/fa/about"}},
      #    %{tag: "link", attrs: %{"rel" => "alternate", "hreflang" => "x-default", "href" => "https://acme.test/about"}}]
  """
  @spec alternate_links([map()], String.t() | nil, String.t() | nil) :: [map()]
  def alternate_links([_, _ | _] = editions, base, site_id) do
    primary = Languages.primary(site_id)

    links =
      Enum.flat_map(editions, fn %{language: language, path: path} ->
        link(%{"rel" => "alternate", "hreflang" => language}, absolute(path, base))
      end)

    fallback =
      case Enum.find(editions, &(&1.language == primary)) do
        %{path: path} ->
          link(%{"rel" => "alternate", "hreflang" => "x-default"}, absolute(path, base))

        nil ->
          []
      end

    links ++ fallback
  end

  def alternate_links(_one_edition, _base, _site_id), do: []

  defp schema(seo, vars, site_title, base) do
    seo.schema
    |> List.wrap()
    |> Enum.flat_map(&stored_object(&1, vars))
    |> case do
      [] -> [web_page(seo, site_title, base)]
      stored -> stored
    end
  end

  # A JSON-LD object with its unresolved values removed, and nothing when none is left.
  defp stored_object(%{} = object, vars) when not is_struct(object) do
    {:ok, kept} = prune(object, vars)
    if map_size(kept) > 0, do: [kept], else: []
  end

  defp stored_object(_not_an_object, _vars), do: []

  defp web_page(seo, site_title, base) do
    site = if site_title && base, do: %{"@type" => "WebSite", "name" => site_title, "url" => base}

    [
      {"@context", "https://schema.org"},
      {"@type", "WebPage"},
      {"name", seo.title},
      {"description", seo.description},
      {"url", seo.url},
      {"inLanguage", seo.language},
      {"image", seo.image},
      {"isPartOf", site}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp fill_vars(seo, %{url: url, image: image}, site_title, base) do
    core = %{
      "page.title" => seo.title,
      "page.url" => url,
      "page.language" => seo.language,
      "page.image" => image,
      "site.name" => site_title,
      "site.url" => base
    }

    own = for {key, value} <- seo.vars, into: %{}, do: {to_string(key), value}

    for {key, value} <- Map.merge(core, own),
        text <- [var_text(value)],
        is_binary(text),
        into: %{},
        do: {key, text}
  end

  # A text with its variables filled, `nil` when it is empty or names one that does not resolve.
  defp filled_text(text, vars) when is_binary(text) do
    case fill(text, vars) do
      {:ok, filled} -> presence(filled)
      :unresolved -> nil
    end
  end

  defp filled_text(_no_text, _vars), do: nil

  defp var_text(value) when is_binary(value), do: presence(value)
  defp var_text(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp var_text(_no_text), do: nil

  defp fill_tags(layer, vars),
    do: for(tag <- List.wrap(layer), {:ok, filled} <- [fill(tag, vars)], do: filled)

  # Every string inside `value` with its variables filled, or `:unresolved` when any one is left.
  defp fill(value, vars) when is_binary(value) do
    filled =
      if String.contains?(value, "{{"),
        do: Regex.replace(@placeholder, value, fn whole, key -> Map.get(vars, key, whole) end),
        else: value

    if String.contains?(filled, "{{") and Regex.match?(@unresolved, filled),
      do: :unresolved,
      else: {:ok, filled}
  end

  defp fill(%{} = map, vars) when not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, filled} ->
      case fill(value, vars) do
        {:ok, value} -> {:cont, {:ok, Map.put(filled, key, value)}}
        :unresolved -> {:halt, :unresolved}
      end
    end)
  end

  defp fill(list, vars) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, filled} ->
      case fill(value, vars) do
        {:ok, value} -> {:cont, {:ok, [value | filled]}}
        :unresolved -> {:halt, :unresolved}
      end
    end)
    |> case do
      {:ok, filled} -> {:ok, Enum.reverse(filled)}
      :unresolved -> :unresolved
    end
  end

  defp fill(value, _vars), do: {:ok, value}

  # Like `fill/2`, removing each value that is left unresolved rather than giving up on the whole.
  defp prune(%{} = map, vars) when not is_struct(map),
    do:
      {:ok,
       for({key, value} <- map, {:ok, kept} <- [prune(value, vars)], into: %{}, do: {key, kept})}

  defp prune(list, vars) when is_list(list),
    do: {:ok, for(value <- list, {:ok, kept} <- [prune(value, vars)], do: kept)}

  defp prune(value, vars), do: fill(value, vars)

  defp tags(layer), do: Enum.flat_map(List.wrap(layer), &tag/1)

  # A later layer drops every earlier tag with the same identity; a tag no later layer names stays,
  # ahead of the later ones.
  defp stack(layers) do
    Enum.reduce(layers, [], fn later, earlier ->
      said = MapSet.new(later, &identity/1)

      earlier
      |> Enum.reject(&MapSet.member?(said, identity(&1)))
      |> Enum.concat(later)
    end)
  end

  defp identity({tag, attrs}), do: {tag, List.keydelete(attrs, Map.fetch!(@value_attrs, tag), 0)}

  defp absolute_tag({tag, attrs} = whole, base) do
    key = Map.fetch!(@value_attrs, tag)

    with true <- Enum.any?(@addresses, fn {name, by, id} -> name == tag and {by, id} in attrs end),
         {^key, "/" <> _ = path} <- List.keyfind(attrs, key, 0),
         url when is_binary(url) <- absolute(path, base) do
      {tag, List.keyreplace(attrs, key, 0, {key, url})}
    else
      _as_stored -> whole
    end
  end

  defp meta_value(tags, key, name) do
    Enum.find_value(tags, fn
      {"meta", attrs} -> if {key, name} in attrs, do: text(List.keyfind(attrs, "content", 0))
      _other -> nil
    end)
  end

  defp numbered(title, number) when is_binary(title) and is_integer(number),
    do: gettext("%{title} – Page %{number}", title: title, number: number)

  defp numbered(title, _first), do: title

  # The identities of the tags that follow what the page set itself.
  defp owned(own, page_description?) do
    [
      {title_value(own), [{"property", "og:title"}, {"name", "twitter:title"}]},
      {page_description?,
       [{"name", "description"}, {"property", "og:description"}, {"name", "twitter:description"}]},
      {meta_value(own, "property", "og:image"), [{"name", "twitter:image"}]}
    ]
    |> Enum.flat_map(fn {set, attrs} -> if set, do: attrs, else: [] end)
    |> MapSet.new(&{"meta", [&1]})
  end

  defp title_value(tags) do
    Enum.find_value(tags, fn
      {"title", attrs} -> text(List.keyfind(attrs, "content", 0))
      _other -> nil
    end)
  end

  defp text({_key, value}) when is_binary(value), do: presence(value)
  defp text(_no_text), do: nil

  # A stored tag is `tag`, `attrs` and `content`, its keys atoms or strings. A `content` beside
  # `attrs` is a meta's `content` attribute and wins over one inside them.
  defp tag(%{} = tag) do
    with name when is_binary(name) <- field(tag, :tag),
         name when is_map_key(@value_attrs, name) <- String.downcase(name),
         [_ | _] = attrs <- attrs(name, field(tag, :attrs), field(tag, :content)) do
      [{name, attrs}]
    else
      _not_a_head_tag -> []
    end
  end

  defp tag(_not_a_tag), do: []

  defp attrs(tag, %{} = attrs, content) do
    attrs
    |> Enum.flat_map(fn {key, value} -> attr(String.downcase(to_string(key)), value) end)
    |> Map.new()
    |> put_content(tag, content)
    |> Enum.sort()
  end

  defp attrs(_tag, _no_attrs, _content), do: []

  defp put_content(attrs, tag, content)
       when tag in ["meta", "title"] and is_binary(content) and content != "",
       do: Map.put(attrs, "content", content)

  defp put_content(attrs, _tag, _content), do: attrs

  defp attr("on" <> _handler, _value), do: []

  defp attr(key, value) do
    if String.match?(key, ~r/\A[a-z][a-z0-9_:.-]*\z/), do: attr_value(key, value), else: []
  end

  defp attr_value(key, value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: [{key, value}]

  defp attr_value(_key, _value), do: []

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  # JSON inside `<script>` is not HTML-decoded, so `<`, `>` and `&` are escaped the JSON way, which
  # every JSON parser reads back as the same character and no HTML parser reads as `</script>`.
  defp json_ld(entry) do
    case Jason.encode(entry) do
      {:ok, json} -> [String.replace(json, ["<", ">", "&"], &json_escape/1)]
      {:error, _reason} -> []
    end
  end

  defp json_escape("<"), do: "\\u003c"
  defp json_escape(">"), do: "\\u003e"
  defp json_escape("&"), do: "\\u0026"

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_no_value), do: nil
end
