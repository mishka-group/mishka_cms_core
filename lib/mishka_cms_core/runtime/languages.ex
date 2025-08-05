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

  ## Names

  `name/1` and `names/1` put a code into a sentence a person reads, in the locale of the calling
  process: `"fa"` is "Persian", and `["fa", "fr"]` is "French and Persian". The names, the region
  template and the "and" are in the `mishka_gervaz` Gettext domain.

  See `MishkaCmsCore.Runtime.PageEditions` for what a page does with its language.
  """

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings

  @setting "site.languages"
  @allowed "site.allowed_languages"
  @required "site.required_languages"
  @capture "lang"
  @default ["en"]
  @session "site_language"
  @admin_session "admin_language"

  # The same rule GuardedStruct's `language_code` validation holds a page's own language to.
  @code ~r/^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$/

  # Written right to left, by the primary subtag — `fa-ir` is Persian as much as `fa` is.
  @right_to_left ~w(ar arc ckb dv fa he ps sd ug ur yi)

  # A language's name, by its primary subtag. `name/1` translates it.
  @names %{
    "af" => dgettext_noop("mishka_gervaz", "Afrikaans"),
    "am" => dgettext_noop("mishka_gervaz", "Amharic"),
    "ar" => dgettext_noop("mishka_gervaz", "Arabic"),
    "az" => dgettext_noop("mishka_gervaz", "Azerbaijani"),
    "be" => dgettext_noop("mishka_gervaz", "Belarusian"),
    "bg" => dgettext_noop("mishka_gervaz", "Bulgarian"),
    "bn" => dgettext_noop("mishka_gervaz", "Bengali"),
    "bs" => dgettext_noop("mishka_gervaz", "Bosnian"),
    "ca" => dgettext_noop("mishka_gervaz", "Catalan"),
    "ckb" => dgettext_noop("mishka_gervaz", "Central Kurdish"),
    "cs" => dgettext_noop("mishka_gervaz", "Czech"),
    "cy" => dgettext_noop("mishka_gervaz", "Welsh"),
    "da" => dgettext_noop("mishka_gervaz", "Danish"),
    "de" => dgettext_noop("mishka_gervaz", "German"),
    "el" => dgettext_noop("mishka_gervaz", "Greek"),
    "en" => dgettext_noop("mishka_gervaz", "English"),
    "eo" => dgettext_noop("mishka_gervaz", "Esperanto"),
    "es" => dgettext_noop("mishka_gervaz", "Spanish"),
    "et" => dgettext_noop("mishka_gervaz", "Estonian"),
    "eu" => dgettext_noop("mishka_gervaz", "Basque"),
    "fa" => dgettext_noop("mishka_gervaz", "Persian"),
    "fi" => dgettext_noop("mishka_gervaz", "Finnish"),
    "fil" => dgettext_noop("mishka_gervaz", "Filipino"),
    "fr" => dgettext_noop("mishka_gervaz", "French"),
    "ga" => dgettext_noop("mishka_gervaz", "Irish"),
    "gl" => dgettext_noop("mishka_gervaz", "Galician"),
    "gu" => dgettext_noop("mishka_gervaz", "Gujarati"),
    "ha" => dgettext_noop("mishka_gervaz", "Hausa"),
    "he" => dgettext_noop("mishka_gervaz", "Hebrew"),
    "hi" => dgettext_noop("mishka_gervaz", "Hindi"),
    "hr" => dgettext_noop("mishka_gervaz", "Croatian"),
    "hu" => dgettext_noop("mishka_gervaz", "Hungarian"),
    "hy" => dgettext_noop("mishka_gervaz", "Armenian"),
    "id" => dgettext_noop("mishka_gervaz", "Indonesian"),
    "is" => dgettext_noop("mishka_gervaz", "Icelandic"),
    "it" => dgettext_noop("mishka_gervaz", "Italian"),
    "ja" => dgettext_noop("mishka_gervaz", "Japanese"),
    "ka" => dgettext_noop("mishka_gervaz", "Georgian"),
    "kk" => dgettext_noop("mishka_gervaz", "Kazakh"),
    "km" => dgettext_noop("mishka_gervaz", "Khmer"),
    "kn" => dgettext_noop("mishka_gervaz", "Kannada"),
    "ko" => dgettext_noop("mishka_gervaz", "Korean"),
    "ku" => dgettext_noop("mishka_gervaz", "Kurdish"),
    "ky" => dgettext_noop("mishka_gervaz", "Kyrgyz"),
    "lo" => dgettext_noop("mishka_gervaz", "Lao"),
    "lt" => dgettext_noop("mishka_gervaz", "Lithuanian"),
    "lv" => dgettext_noop("mishka_gervaz", "Latvian"),
    "mk" => dgettext_noop("mishka_gervaz", "Macedonian"),
    "ml" => dgettext_noop("mishka_gervaz", "Malayalam"),
    "mn" => dgettext_noop("mishka_gervaz", "Mongolian"),
    "mr" => dgettext_noop("mishka_gervaz", "Marathi"),
    "ms" => dgettext_noop("mishka_gervaz", "Malay"),
    "mt" => dgettext_noop("mishka_gervaz", "Maltese"),
    "my" => dgettext_noop("mishka_gervaz", "Burmese"),
    "nb" => dgettext_noop("mishka_gervaz", "Norwegian Bokmål"),
    "ne" => dgettext_noop("mishka_gervaz", "Nepali"),
    "nl" => dgettext_noop("mishka_gervaz", "Dutch"),
    "no" => dgettext_noop("mishka_gervaz", "Norwegian"),
    "pa" => dgettext_noop("mishka_gervaz", "Punjabi"),
    "pl" => dgettext_noop("mishka_gervaz", "Polish"),
    "ps" => dgettext_noop("mishka_gervaz", "Pashto"),
    "pt" => dgettext_noop("mishka_gervaz", "Portuguese"),
    "ro" => dgettext_noop("mishka_gervaz", "Romanian"),
    "ru" => dgettext_noop("mishka_gervaz", "Russian"),
    "sd" => dgettext_noop("mishka_gervaz", "Sindhi"),
    "si" => dgettext_noop("mishka_gervaz", "Sinhala"),
    "sk" => dgettext_noop("mishka_gervaz", "Slovak"),
    "sl" => dgettext_noop("mishka_gervaz", "Slovenian"),
    "so" => dgettext_noop("mishka_gervaz", "Somali"),
    "sq" => dgettext_noop("mishka_gervaz", "Albanian"),
    "sr" => dgettext_noop("mishka_gervaz", "Serbian"),
    "sv" => dgettext_noop("mishka_gervaz", "Swedish"),
    "sw" => dgettext_noop("mishka_gervaz", "Swahili"),
    "ta" => dgettext_noop("mishka_gervaz", "Tamil"),
    "te" => dgettext_noop("mishka_gervaz", "Telugu"),
    "tg" => dgettext_noop("mishka_gervaz", "Tajik"),
    "th" => dgettext_noop("mishka_gervaz", "Thai"),
    "tk" => dgettext_noop("mishka_gervaz", "Turkmen"),
    "tr" => dgettext_noop("mishka_gervaz", "Turkish"),
    "ug" => dgettext_noop("mishka_gervaz", "Uyghur"),
    "uk" => dgettext_noop("mishka_gervaz", "Ukrainian"),
    "ur" => dgettext_noop("mishka_gervaz", "Urdu"),
    "uz" => dgettext_noop("mishka_gervaz", "Uzbek"),
    "vi" => dgettext_noop("mishka_gervaz", "Vietnamese"),
    "yi" => dgettext_noop("mishka_gervaz", "Yiddish"),
    "yo" => dgettext_noop("mishka_gervaz", "Yoruba"),
    "zh" => dgettext_noop("mishka_gervaz", "Chinese"),
    "zu" => dgettext_noop("mishka_gervaz", "Zulu")
  }

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
  A language's name, translated in the `mishka_gervaz` domain, for a sentence a person reads. A
  region follows through the `"%{language} (%{region})"` template; a code with no name here reads as
  the code itself, upper-cased.

      Languages.name("fa")    #=> "Persian"
      Languages.name("pt-BR") #=> "Portuguese (BR)"
      Languages.name("xx")    #=> "XX"
      Languages.name(nil)     #=> nil
  """
  @spec name(String.t() | atom() | nil) :: String.t() | nil
  def name(nil), do: nil
  def name(language) when is_atom(language), do: language |> Atom.to_string() |> name()

  def name(language) when is_binary(language) do
    case language |> clean() |> String.split("-") do
      [""] -> nil
      [primary | subtags] -> named(Map.get(@names, primary), subtags, clean(language))
    end
  end

  defp named(nil, _subtags, code), do: String.upcase(code)
  defp named(name, [], _code), do: translated(name)

  defp named(name, subtags, _code) do
    dgettext("mishka_gervaz", "%{language} (%{region})",
      language: translated(name),
      region: subtags |> Enum.join("-") |> String.upcase()
    )
  end

  defp translated(name), do: Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", name)

  @known @names |> Map.keys() |> Enum.sort()

  @doc """
  Every language code `name/1` has a name for, in the order of the codes: the languages a list of
  choices offers.

      Languages.known() #=> ["af", "am", "ar", …, "zu"]
  """
  @spec known() :: [String.t()]
  def known, do: @known

  @doc """
  Several languages as one phrase: each named by `name/1`, once, in alphabetical order of those
  names, joined by `join/1`.

  The alphabet is the `"alphabet"` message of the `mishka_gervaz` domain, every letter in order, so
  each language sorts by its own. A letter it does not hold sorts as its letter without accents,
  else after every letter it holds.

      Languages.names(["fa", "fr"])       #=> "French and Persian"
      Languages.names(["de", "fa", "fr"]) #=> "French, German and Persian"
      Languages.names([])                 #=> ""
  """
  @spec names([String.t() | atom() | nil]) :: String.t()
  def names(languages) when is_list(languages) do
    languages
    |> Enum.map(&name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> alphabetical()
    |> join()
  end

  defp alphabetical(names) do
    gettext_comment(
      "Every letter of the alphabet, in lower case and in order, with no spaces. Lists of names, such as of languages, are sorted by it."
    )

    rank =
      "mishka_gervaz"
      |> dpgettext("alphabet", "abcdefghijklmnopqrstuvwxyz")
      |> String.graphemes()
      |> Enum.with_index()
      |> Map.new()

    Enum.sort_by(names, &sort_key(&1, rank))
  end

  defp sort_key(name, rank) do
    name
    |> String.downcase()
    |> String.graphemes()
    |> Enum.map(fn letter ->
      Map.get(rank, letter) || Map.get(rank, unaccented(letter)) ||
        map_size(rank) + first_codepoint(letter)
    end)
  end

  defp unaccented(letter) do
    <<base::utf8, _marks::binary>> = :unicode.characters_to_nfd_binary(letter)
    <<base::utf8>>
  end

  defp first_codepoint(<<codepoint::utf8, _rest::binary>>), do: codepoint

  @doc """
  Phrases as one, in the order given: all but the last joined by the `"list separator"` `", "`,
  and the last added through the `"%{rest} and %{last}"` template, both in the `mishka_gervaz`
  domain.

      Languages.join(["a", "b", "c"]) #=> "a, b and c"
  """
  @spec join([String.t()]) :: String.t()
  def join([]), do: ""
  def join([only]), do: only

  def join(phrases) do
    {rest, [last]} = Enum.split(phrases, -1)

    dgettext("mishka_gervaz", "%{rest} and %{last}",
      rest: Enum.join(rest, dpgettext("mishka_gervaz", "list separator", ", ")),
      last: last
    )
  end

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
