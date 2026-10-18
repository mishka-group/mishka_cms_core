# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Languages do
  @moduledoc """
  The languages a site publishes in, and what the runtime makes of a path segment that names one.

  ## The site's list

  `site.languages` is a setting a site may override — see `MishkaCmsCore.Settings` — holding codes:
  `["en", "fa", "ar"]`. A site that sets none reads the global value, and a global that sets none
  reads `default/0`.

  ## What a master allows, and what a master requires

  Two master-only global settings bound every site's list — see `allowed/0` and `required/0`. A
  site may list only allowed languages (all of them, while none is set), and every required one is
  part of every site's list whether the site listed it or not. `site/1` answers with both applied, so
  every reader — routing, the language plug, `t/1`, the translations admin — sees the same list.

  ## A capture named `lang`

  A page stored at `/:lang/about` answers `/fa/about` only when `fa` is one of its site's languages.
  Without that check the capture takes anything — `/xyz/about`, `/favicon.ico/about` — and the page
  renders as though it had been written in a language nobody wrote it in. So
  `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState` asks `admits?/3` before it keeps a match,
  and a request whose `lang` is not the site's falls through to the next pattern, or to the 404.

  Wherever the capture sits: `/docs/:lang/:section` and `/shop/:category/:lang` are checked the same
  way, and so is a `*lang` rest capture. No other capture name is ever checked against languages.

  ## Failing safe

  A list that cannot be read — no such site, a value that is not a list, a cache that is not there —
  is `default/0`. So is one with nothing usable left in it, because a site that answers no language
  at all would 404 every page that has a `lang` in its path. Each code is trimmed and downcased, and
  anything that is not a language code is dropped rather than admitted. The settings page refuses to
  store such a list (`valid?/1`); this is for one that reached the store some other way.

  ## Public addresses

  `site.language_urls` decides how an address names its language — see `url_mode/1`. Every public
  address the CMS builds comes out of `url/3`, and a request whose first segment names no language
  is read through `implied/2`. A stored path is the same in both modes, so switching modes rewrites
  no page.

  ## Names

  `name/1` and `names/1` put a code into a sentence a person reads, in the locale of the calling
  process: `"fa"` is "Persian", and `["fa", "fr"]` is "French and Persian". The names, their
  alphabetical order and the "and" are Unicode CLDR's, through `MishkaCmsCore.Localized`; nothing
  is translated by hand.

  See `MishkaCmsCore.Runtime.PageEditions` for what a page does with its language.
  """

  alias MishkaCmsCore.Localized
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings

  @setting "site.languages"
  @allowed "site.allowed_languages"
  @required "site.required_languages"
  @url_setting "site.language_urls"
  @prefix_others "prefix_others"
  @prefix_all "prefix_all"
  @capture "lang"
  @default ["en"]
  @session "site_language"
  @admin_session "admin_language"

  # The same rule GuardedStruct's `language_code` validation holds a page's own language to.
  @code ~r/^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$/

  # Written right to left, by the primary subtag — `fa-ir` is Persian as much as `fa` is.
  @right_to_left ~w(ar arc ckb dv fa he ps sd ug ur yi)

  # The languages a list of choices offers, by their codes. CLDR names each one in every language
  # (`name/1`).
  @known ~w(af am ar az be bg bn bs ca ckb cs cy da de el en eo es et eu fa fi fil fr ga gl gu ha
           he hi hr hu hy id is it ja ka kk km kn ko ku ky lo lt lv mk ml mn mr ms mt my nb ne nl
           no pa pl ps pt ro ru sd si sk sl so sq sr sv sw ta te tg th tk tr ug uk ur uz vi yi yo
           zh zu)

  @doc "What a site publishes in when nothing says otherwise."
  @spec default() :: [String.t()]
  def default, do: @default

  @doc "The name of the capture whose value must be one of the site's languages."
  @spec capture() :: String.t()
  def capture, do: @capture

  @doc "The session key a visitor's chosen language is remembered under."
  @spec session() :: String.t()
  def session, do: @session

  @doc "The session key the language an admin reads the dashboard in is kept under."
  @spec admin_session() :: String.t()
  def admin_session, do: @admin_session

  @doc """
  The language an admin reads the dashboard in: the one kept in `session`, else English.

      Languages.admin(%{"admin_language" => "fa"}) #=> "fa"
      Languages.admin(%{})                         #=> "en"
  """
  @spec admin(map()) :: String.t()
  def admin(%{@admin_session => language}) when is_binary(language), do: language
  def admin(_session), do: hd(@default)

  @doc """
  The languages an admin of `site_id` may read the dashboard in: the site's own, and English.

      Languages.admin_choices(site.id) #=> ["fa", "de", "en"]
  """
  @spec admin_choices(String.t() | nil) :: [String.t()]
  def admin_choices(site_id), do: Enum.uniq(site(site_id) ++ @default)

  @doc """
  The languages a site publishes in, by its id — its own list, else the global one, else `default/0`.

      Languages.site(site.id)
      #=> ["en", "fa"]
  """
  @spec site(String.t() | nil) :: [String.t()]
  def site(site_id) do
    @setting
    |> Settings.get(@default, site_id)
    |> normalize()
    |> bounded(allowed(), required())
  end

  @doc """
  The languages a master lets sites publish in — the global `site.allowed_languages`. Empty means
  any language.
  """
  @spec allowed() :: [String.t()]
  def allowed, do: master_list(@allowed)

  @doc """
  The languages a master has every site publish in — the global `site.required_languages`. Empty
  means none is required.
  """
  @spec required() :: [String.t()]
  def required, do: master_list(@required)

  # Read from the GLOBAL row only: these are a master's, and a row a site wrote under the same key is
  # not one this reads.
  defp master_list(key) do
    case Settings.get(key, [], nil) do
      languages when is_list(languages) ->
        languages |> Enum.filter(&code?/1) |> Enum.map(&clean/1) |> Enum.uniq()

      _not_a_list ->
        []
    end
  end

  # THE SITE'S OWN ORDER, NARROWED AND THEN COMPLETED: its first language stays its default. A list
  # the narrowing empties falls to the required languages, else the first allowed, else `default/0`.
  defp bounded(languages, allowed, required) do
    kept = if allowed == [], do: languages, else: Enum.filter(languages, &(&1 in allowed))

    case kept ++ Enum.reject(required, &(&1 in kept)) do
      [] -> first_allowed(allowed)
      languages -> languages
    end
  end

  defp first_allowed([first | _rest]), do: [first]
  defp first_allowed([]), do: @default

  @doc """
  `site/1` for the site the routing table knows by `name` — which is how
  `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState` names one. A name it does not know reads
  `default/0`.
  """
  @spec site_named(String.t()) :: [String.t()]
  def site_named(name) do
    case SiteState.get_by_name(name) do
      {:ok, %{id: site_id}} -> site(site_id)
      _unknown -> @default
    end
  end

  @doc """
  Whether `languages` may be stored as a site's list: at least one code, and each of them a language
  code, in any case.

  What `site.languages` is held to when it is written — see `MishkaCmsCore.Settings.cast/2` — so an
  admin who types `English, Persian`, or empties the field, is told it was not saved rather than
  finding every `:lang` page answering English alone.

      Languages.valid?(["en", "FA", "pt-br"]) #=> true
      Languages.valid?(["en", "Persian"])     #=> false
      Languages.valid?([])                    #=> false
  """
  @spec valid?(term()) :: boolean()
  def valid?([_ | _] = languages), do: Enum.all?(languages, &(code?(&1) and allowed?(&1)))
  def valid?(_languages), do: false

  @doc """
  `valid?/1` for a master's own lists, which may be empty — "no limit", "nothing required" — and are
  not held to the allowed list, being what sets it.
  """
  @spec codes_or_empty?(term()) :: boolean()
  def codes_or_empty?(languages) when is_list(languages), do: Enum.all?(languages, &code?/1)
  def codes_or_empty?(_languages), do: false

  defp allowed?(code) do
    case allowed() do
      [] -> true
      allowed -> clean(code) in allowed
    end
  end

  defp code?(code) when is_binary(code), do: Regex.match?(@code, clean(code))
  defp code?(_code), do: false

  defp clean(code), do: code |> String.trim() |> String.downcase()

  @doc """
  Whether a captured value may stand in a pattern. A `lang` capture must be one of `languages`;
  every other capture takes whatever the visitor asked for.
  """
  @spec admits?(String.t(), String.t(), [String.t()]) :: boolean()
  def admits?(@capture, value, languages), do: value in languages
  def admits?(_name, _value, _languages), do: true

  @doc "Whether a stored path captures `lang` in any segment, as `:lang` or as `*lang`."
  @spec captures?(String.t() | nil) :: boolean()
  def captures?(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.any?(&(&1 in [":" <> @capture, "*" <> @capture]))
  end

  def captures?(_path), do: false

  @doc """
  The direction a language is written in, as the value of `<html dir>`.

      Languages.direction("fa")    #=> "rtl"
      Languages.direction("en-gb") #=> "ltr"
  """
  @spec direction(String.t() | nil) :: String.t()
  def direction(language) when is_binary(language) do
    [primary | _subtags] = language |> String.downcase() |> String.split("-")
    if primary in @right_to_left, do: "rtl", else: "ltr"
  end

  def direction(_language), do: "ltr"

  @doc """
  A language's name in the language of the calling process, for a sentence a person reads — CLDR's
  (`MishkaCmsCore.Localized.language/2`). A code CLDR does not name reads as the code itself,
  upper-cased.

      Languages.name("fa")    #=> "Persian"
      Languages.name("pt-BR") #=> "Brazilian Portuguese"
      Languages.name("fa-IR") #=> "Persian (Iran)"
      Languages.name("xx")    #=> "XX"
      Languages.name(nil)     #=> nil
  """
  @spec name(String.t() | atom() | nil) :: String.t() | nil
  def name(nil), do: nil
  def name(language) when is_atom(language), do: language |> Atom.to_string() |> name()

  def name(language) when is_binary(language) do
    case clean(language) do
      "" -> nil
      code -> Localized.language(code) || String.upcase(code)
    end
  end

  @doc """
  Every language code `name/1` has a name for, in the order of the codes: the languages a list of
  choices offers.

      Languages.known() #=> ["af", "am", "ar", …, "zu"]
  """
  @spec known() :: [String.t()]
  def known, do: @known

  @doc """
  Several languages as one phrase: each named by `name/1`, once, in the alphabetical order of the
  reader's language, joined as that language joins a list (`join/1`).

      Languages.names(["fa", "fr"])       #=> "French and Persian"
      Languages.names(["de", "fa", "fr"]) #=> "French, German, and Persian"
      Languages.names([])                 #=> ""
  """
  @spec names([String.t() | atom() | nil]) :: String.t()
  def names(languages) when is_list(languages) do
    languages
    |> Enum.map(&name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Localized.sort()
    |> join()
  end

  @doc """
  Phrases as one, in the order given, joined as the reader's language joins a list
  (`MishkaCmsCore.Localized.list/2`).

      Languages.join(["a", "b", "c"]) #=> "a, b, and c"
  """
  @spec join([String.t()]) :: String.t()
  def join(phrases) when is_list(phrases), do: Localized.list(phrases)

  @doc """
  The language a site answers in when a request names none — the FIRST of its list.

  There is no separate "default language" setting, and there should not be: `site.languages` is
  already ordered and already validated, so moving a code to the front of it is how an admin changes
  what the site leads with. A second setting could disagree with the list, and then one of them would
  be wrong.

      Languages.primary(site.id) #=> "en"
  """
  @spec primary(String.t() | nil) :: String.t()
  def primary(site_id), do: site_id |> site() |> List.first(hd(@default))

  @doc """
  `language` when the site still publishes in it, and `nil` otherwise.

  What a remembered language is put through before it is used. A visitor's session outlives the
  setting that justified it: a site that drops `fa` from its list would otherwise keep sending
  everyone who ever chose it to Persian addresses that now 404.

      Languages.remembered("fa", site.id) #=> "fa"
      Languages.remembered("de", site.id) #=> nil
  """
  @spec remembered(term(), String.t() | nil) :: String.t() | nil
  def remembered(language, site_id) when is_binary(language) do
    if language in site(site_id), do: language, else: nil
  end

  def remembered(_language, _site_id), do: nil

  @doc """
  The language a path names in its first segment, or `nil`.

  Only the first segment, and only against the site's own list — `/fa/pricing` is Persian,
  `/favicon.ico` is not a language and never was.

      Languages.leading(["fa", "pricing"], ["en", "fa"]) #=> "fa"
      Languages.leading(["pricing"], ["en", "fa"])       #=> nil
  """
  @spec leading([String.t()], [String.t()]) :: String.t() | nil
  def leading([segment | _rest], languages) when is_binary(segment) do
    if segment in languages, do: segment, else: nil
  end

  def leading(_segments, _languages), do: nil

  @doc """
  How the public addresses of `site_id` name their language — its `site.language_urls` setting:

    * `"prefix_others"` — the primary language (`primary/1`) has no prefix, every other has its
      own: `/blog`, `/fa/blog`;
    * `"prefix_all"` — every language has its own: `/en/blog`, `/fa/blog`.

  Any other value reads `"prefix_others"`.

      Languages.url_mode(site.id) #=> "prefix_others"
  """
  @spec url_mode(String.t() | nil) :: String.t()
  def url_mode(site_id) do
    case Settings.get(@url_setting, @prefix_others, site_id) do
      @prefix_all -> @prefix_all
      _prefix_others -> @prefix_others
    end
  end

  @doc "The values `url_mode/1` answers, the default first."
  @spec url_modes() :: [String.t()]
  def url_modes, do: [@prefix_others, @prefix_all]

  @doc """
  The public address a stored path makes on the site `site_id` with these captures, or `nil` when
  it makes none.

  `path` is what a page is stored under — a literal, or a pattern holding `:name` and `*name`
  segments. Three steps:

    1. each capture is filled from `captures`, by its name as a string — percent-encoded, a
       `*name` one segment at a time — and a capture `captures` does not hold is `nil`;
    2. a `lang` capture whose value is not one of the site's languages is `nil` — the resolver would
       refuse that address;
    3. in `"prefix_others"` (`url_mode/1`), a FIRST segment that is the primary language is
       dropped: `/en` is `/`, `/en/blog/x` is `/blog/x`. Only the first segment is ever a language
       prefix; a `lang` anywhere else in the path stays as it is.

  Every public address the CMS builds comes out of this — a link in a template
  (`MishkaCmsCore.Runtime.LiveViewHelpers.site_path/2`), a page's editions, the sitemap,
  robots.txt, a redirect — so no two of them can name one page differently.

      # site.languages ["en", "fa"], site.language_urls "prefix_others"
      Languages.url("/:lang/blog", %{"lang" => "en"}, site.id)  #=> "/blog"
      Languages.url("/:lang/blog", %{"lang" => "fa"}, site.id)  #=> "/fa/blog"
      Languages.url("/:lang/blog", %{"lang" => "de"}, site.id)  #=> nil
      Languages.url("/en/pricing", %{}, site.id)                #=> "/pricing"
      Languages.url("/:lang/blog/:slug", %{"lang" => "fa"}, site.id) #=> nil
  """
  @spec url(String.t(), map(), String.t() | nil) :: String.t() | nil
  def url(path, captures, site_id), do: url(path, captures, site_id, url_mode(site_id))

  @doc """
  `url/3` in `mode` rather than the site's own — for a caller comparing addresses as they would be
  in either mode.
  """
  @spec url(String.t(), map(), String.t() | nil, String.t()) :: String.t() | nil
  def url(path, captures, site_id, mode) when is_binary(path) and is_map(captures) do
    languages = site(site_id)

    with true <- admitted?(path, captures, languages),
         filled when is_binary(filled) <- fill(path, captures) do
      if mode == @prefix_all, do: filled, else: unprefixed(filled, hd(languages))
    else
      _not_an_address -> nil
    end
  end

  def url(_path, _captures, _site_id, _mode), do: nil

  defp admitted?(path, captures, languages) do
    not captures?(path) or Map.get(captures, @capture) in languages
  end

  defp unprefixed(path, primary) do
    case String.split(path, "/", trim: true) do
      [^primary | rest] -> "/" <> Enum.join(rest, "/")
      _other -> path
    end
  end

  # A capture is percent-encoded, each segment of a `*name` one on its own; a literal segment is kept
  # as it is stored. `nil` when the path needs a capture `captures` does not hold.
  defp fill(path, captures) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce_while([], fn segment, filled ->
      case filled_segment(segment, captures) do
        nil -> {:halt, nil}
        value -> {:cont, [value | filled]}
      end
    end)
    |> case do
      nil -> nil
      filled -> "/" <> (filled |> Enum.reverse() |> Enum.join("/"))
    end
  end

  defp filled_segment(":" <> name, captures), do: captures |> Map.get(name) |> encode()

  defp filled_segment("*" <> name, captures) do
    case Map.get(captures, name) do
      rest when is_binary(rest) and rest != "" ->
        rest |> String.split("/") |> Enum.map_join("/", &encode/1)

      _missing ->
        nil
    end
  end

  defp filled_segment(literal, _captures), do: literal

  defp encode(value) when is_binary(value) and value != "",
    do: URI.encode(value, &URI.char_unreserved?/1)

  defp encode(_missing), do: nil

  @doc """
  The language a request whose first segment names none is answered in: the site's primary language
  while it is left unprefixed (`"prefix_others"`), else `nil` — as it is when the first segment is
  one of the site's languages.

  What `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.resolve/2` reads `/blog` as, and what
  `MishkaCmsCore.Runtime.Plugs.LanguagePlug` serves it in.

      Languages.implied(["blog"], site.id)       #=> "en"
      Languages.implied(["fa", "blog"], site.id) #=> nil
  """
  @spec implied([String.t()], String.t() | nil) :: String.t() | nil
  def implied(segments, site_id) do
    languages = site(site_id)

    if url_mode(site_id) == @prefix_others and is_nil(leading(segments, languages)),
      do: hd(languages)
  end

  defp normalize(languages) when is_list(languages) do
    languages
    |> Enum.filter(&code?/1)
    |> Enum.map(&clean/1)
    |> Enum.uniq()
    |> case do
      [] -> @default
      codes -> codes
    end
  end

  defp normalize(_not_a_list), do: @default
end
