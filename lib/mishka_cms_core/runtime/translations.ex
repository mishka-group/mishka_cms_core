defmodule MishkaCmsCore.Runtime.Translations do
  @moduledoc """
  The words a runtime template asks for with `t/1`, and where they come from.

  `MishkaCmsCore.Runtime.Translation` is the table and `MishkaCmsCore.Runtime.States.TranslationsState`
  the ETS copy of it; this is everything around them — the render-time lookup, which keys a
  template asks for, and registering them when it is saved. It stands to those two as
  `MishkaCmsCore.Settings` stands to `MishkaCmsCore.Runtime.Setting` and `SettingsState`.

  ## At render

      <h2>{t("Categories")}</h2>
      <p>{t("Read %{count} posts", count: @count)}</p>

  `translate/2` answers from ETS alone, in this order, and never raises:

    1. this site's own row for the language being answered in
    2. the global row (`site_id` nil) for that language
    3. the key itself

  The language is Gettext's locale for this process and the site is `put_site/1`'s — both set in the
  same two places, `MishkaCmsCore.Runtime.Plugs.LanguagePlug` and `MishkaCmsWeb.RuntimeLive`, so a
  template never passes either. What comes back is a plain string; HEEx escapes it like any other,
  so a translation cannot put markup on the page.

  ## A key is a literal

  Only a double-quoted string literal passed straight to `t/1` is a key: `t("Categories")` is
  registered when its template is saved, `t(@label)` cannot be — its value does not exist until the
  page renders. The same limit Gettext has, for the same reason.

  ## Where keys are read from

  A component, page or layout asks for a key in its `template` and in the `code` of its
  `helpers`, `events` and `infos` — `t/1` is imported into all of them. `source_keys/1` reads all
  four, and it is the one rule that saving a record
  (`MishkaCmsCore.Runtime.Resources.Changes.RegisterTranslationKeys`), `used_keys/1`, `sync/1`,
  `purge_unused/2`, `component_words/1` and the builder's Translations sheet use.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.{Component, Languages, Layout, Page, Translation}
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Runtime.States.{SiteState, TranslationsState}
  alias MishkaGervaz.Table.Web.{DataLoader, Events}

  require Ash.Query

  @site_key :mishka_cms_translation_site

  # A CALL TO `t` AND NOT TO SOMETHING ENDING IN `t`. The lookbehind refuses `format(`, `list(`,
  # `Foo.t(`, and `:t(`; the capture is a double-quoted literal, escapes included.
  @call ~r/(?<![\w.:])t\(\s*"((?:[^"\\]|\\.)*)"/u

  @placeholder ~r/%\{(\w+)\}/u

  # Every runtime-compiled template, which is everything `t/1` is imported into.
  @sources [Component, Page, Layout]

  # The fields of a record whose entries hold code that `t/1` is imported into.
  @code_fields [:helpers, :events, :infos]

  @doc """
  What `t/1` returns: `key` in the language this process is answering in, else the key itself.

      Translations.translate("Categories")                   #=> "دسته‌بندی‌ها"
      Translations.translate("Read %{count} posts", count: 3) #=> "Read 3 posts"
  """
  @spec translate(term(), keyword() | map()) :: String.t()
  def translate(key, bindings \\ [])

  def translate(key, bindings) when is_binary(key) do
    site()
    |> TranslationsState.lookup(Gettext.get_locale(MishkaCmsCore.Gettext), key)
    |> Kernel.||(key)
    |> interpolate(bindings)
  end

  # `t(@label)` with nothing assigned is still something to render — an empty string, never a crash.
  # A value with no string form at all (a map, a pid) renders as nothing rather than taking the page
  # down, which is what `to_string/1` on it would do.
  def translate(key, bindings) do
    case String.Chars.impl_for(key) do
      nil -> ""
      _printable -> key |> to_string() |> interpolate(bindings)
    end
  end

  @doc """
  Names the site this process is answering for, so `translate/2` knows whose rows to read and
  `MishkaCmsCore.Runtime.LiveViewHelpers.component/1` whose components it may render.

  Called beside `Gettext.put_locale/2` in `MishkaCmsWeb.RuntimeLive` and
  `MishkaCmsWeb.DraftPreviewLive`, and by `MishkaCmsWeb.ErrorHTML` and the builder's canvas — every
  process that renders runtime templates for one site. A render for one site among others goes
  through `MishkaCmsCore.Runtime.LiveViewHelpers.rendering_for/2` instead.
  """
  @spec put_site(String.t() | nil) :: :ok
  def put_site(site_id) do
    Process.put(@site_key, site_id)
    :ok
  end

  @doc """
  The site `put_site/1` named for this process, or `nil` when none was.
  """
  @spec site() :: String.t() | nil
  def site, do: Process.get(@site_key)

  @doc """
  The keys a template asks for, in the order it first asks, each once.

      Translations.keys(~s|<h2>{t("Categories")}</h2><a>{t("Tags")}</a>|)
      #=> ["Categories", "Tags"]
  """
  @spec keys(term()) :: [String.t()]
  def keys(template) when is_binary(template) do
    @call
    |> Regex.scan(template, capture: :all_but_first)
    |> Enum.flat_map(fn [literal] -> literal(literal) end)
    |> Enum.uniq()
  end

  def keys(_no_template), do: []

  @doc """
  The keys a component, page or layout asks for — in its `template` and in the `code` of each of
  its `helpers`, `events` and `infos` — in the order it first asks, each once. A field the record
  does not have asks for nothing; an entry's code is read under `:code` or `"code"`.

      Translations.source_keys(%{
        template: ~s|<h2>{t("Categories")}</h2>|,
        events: [%{name: "save", code: ~s|{:noreply, put_flash(socket, :info, t("Saved"))}|}]
      })
      #=> ["Categories", "Saved"]
  """
  @spec source_keys(map()) :: [String.t()]
  def source_keys(record) when is_map(record) do
    [Map.get(record, :template) | Enum.flat_map(@code_fields, &codes(Map.get(record, &1)))]
    |> Enum.flat_map(&keys/1)
    |> Enum.uniq()
  end

  @doc """
  The fields of `resource` that `source_keys/1` reads: `:template` and whichever of `:helpers`,
  `:events` and `:infos` it has.
  """
  @spec source_fields(Ash.Resource.t()) :: [atom()]
  def source_fields(resource),
    do: [:template | Enum.filter(@code_fields, &Ash.Resource.Info.attribute(resource, &1))]

  defp codes(entries) when is_list(entries), do: Enum.map(entries, &code/1)
  defp codes(_no_entries), do: []

  defp code(%{code: code}), do: code
  defp code(%{"code" => code}), do: code
  defp code(_no_code), do: nil

  @doc """
  Makes sure `site_id` has a row for every key in `keys`, in every language in `languages/1`.

  A row that already exists is left exactly as it is — see `MishkaCmsCore.Runtime.Translation`'s
  `:register`. Only the missing rows are written, and each is announced on the resource's PubSub
  like any other create, so an admin list open on the words sees them arrive without a reload.
  Registering what is already there writes, and announces, nothing.
  """
  @spec register(String.t() | nil, [String.t()]) :: :ok
  def register(_site_id, []), do: :ok

  def register(site_id, keys) do
    held = held(site_id, keys)

    # IN ONE ORDER FOR EVERY SAVE. The rows are written inside the saving record's transaction, and
    # two saves adding the same new keys in opposite orders would each hold a row the other waits
    # for — a deadlock Postgres ends by failing one of the saves. Sorted, the second simply waits.
    rows =
      for key <- Enum.sort(keys),
          language <- Enum.sort(languages(site_id)),
          not MapSet.member?(held, {key, language}),
          do: %{key: key, language: language, site_id: site_id}

    # STILL AN UPSERT: another save may write the same row between the read above and this insert,
    # and `upsert_fields []` leaves that row, value and all, exactly as the other save wrote it.
    if rows != [] do
      Ash.bulk_create(rows, Translation, :register,
        authorize?: false,
        upsert?: true,
        upsert_identity: :unique_translation,
        upsert_fields: [],
        return_errors?: true,
        stop_on_error?: false,
        notify?: true
      )
    end

    :ok
  end

  defp held(site_id, keys) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key in ^keys)
    |> within_site(site_id)
    |> Ash.Query.select([:key, :language])
    |> Ash.read!(authorize?: false, page: false)
    |> MapSet.new(&{&1.key, &1.language})
  end

  @doc """
  Each record's key in every language, for the admin list's chips: `[%{language, translated?}]` —
  `languages/1`'s order for its site first, then any other language it has a row in. One query for
  the whole page of records, whatever their sites.
  """
  @spec language_states([Translation.t()]) :: [[%{language: String.t(), translated?: boolean()}]]
  def language_states([]), do: []

  def language_states(records) do
    keys = records |> Enum.map(& &1.key) |> Enum.uniq()

    held =
      Translation
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(key in ^keys)
      |> Ash.Query.select([:key, :site_id, :language, :value])
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.group_by(&{&1.key, &1.site_id})

    ordered = records |> Enum.map(& &1.site_id) |> Enum.uniq() |> Map.new(&{&1, languages(&1)})

    Enum.map(records, fn record ->
      rows = Map.get(held, {record.key, record.site_id}, [])
      done = for row <- rows, row.value not in [nil, ""], into: MapSet.new(), do: row.language

      ordered
      |> Map.fetch!(record.site_id)
      |> Enum.concat(rows |> Enum.map(& &1.language) |> Enum.sort())
      |> Enum.uniq()
      |> Enum.map(&%{language: &1, translated?: MapSet.member?(done, &1)})
    end)
  end

  @doc """
  The words the components a template renders ask for, nested components included, by the site each
  component belongs to: `%{site_id => [key]}`.

  `refs` are the template's own `<.component>` calls as `{component_name, site_name}` — a site of
  `nil` or `"Global"` is a global component, as it is at render. Each level of nesting is one query,
  and a component already seen is not read again, so a cycle ends.
  """
  @spec component_words([{String.t(), String.t() | nil}]) :: %{(String.t() | nil) => [String.t()]}
  def component_words(refs), do: walk_components(resolve_refs(refs), MapSet.new(), %{})

  defp walk_components([], _seen, words), do: words

  defp walk_components(level, seen, words) do
    level = Enum.reject(level, &MapSet.member?(seen, &1))
    seen = Enum.into(level, seen)

    components = components_at(level)

    words =
      Enum.reduce(components, words, fn component, acc ->
        case source_keys(component) do
          [] -> acc
          found -> Map.update(acc, component.site_id, found, &Enum.uniq(&1 ++ found))
        end
      end)

    next = components |> Enum.flat_map(&component_refs(&1.template)) |> resolve_refs()
    walk_components(next, seen, words)
  end

  defp components_at([]), do: []

  defp components_at(level) do
    names = level |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    wanted = MapSet.new(level)

    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name in ^names and active == true)
    |> Ash.Query.select([:name, :site_id | source_fields(Component)])
    |> Ash.stream!(authorize?: false)
    |> Enum.filter(&MapSet.member?(wanted, {&1.name, &1.site_id}))
  end

  @component_tag ~r/<\.component\b[^>]*>/s
  @component_name ~r/\bcomponent_name="([^"]+)"/
  @component_site ~r/\bsite="([^"]+)"/

  # A template's own `<.component component_name="…" site="…">` calls; a name given as an expression
  # names nothing that can be read ahead of render.
  defp component_refs(template) when is_binary(template) do
    for [tag] <- Regex.scan(@component_tag, template),
        name = attribute(@component_name, tag),
        is_binary(name),
        do: {name, attribute(@component_site, tag)}
  end

  defp component_refs(_template), do: []

  defp attribute(pattern, tag) do
    case Regex.run(pattern, tag) do
      [_all, value] -> value
      nil -> nil
    end
  end

  # `{name, site_name}` to `{name, site_id}`; a site the cache does not know renders nothing.
  defp resolve_refs(refs) do
    for {name, site} <- refs, site_id <- site_id_of(site), uniq: true, do: {name, site_id}
  end

  defp site_id_of(site) when site in [nil, "", "Global"], do: [nil]

  defp site_id_of(site) do
    case SiteState.get_by_name(site) do
      {:ok, %{id: id}} -> [id]
      _unknown -> []
    end
  end

  @doc """
  Whether a row for `site_id` is still asked for: the keys (`source_keys/1`) of the components,
  pages and layouts that render on that site — its own and the global ones — or, for a global row,
  the keys of every one there is, since a global row serves every site.

  Read on demand rather than stored, so it cannot disagree with what the templates say now. It is
  what the admin's Used column asks; nothing on a visitor's path calls it.
  """
  @spec used_keys(String.t() | nil) :: MapSet.t(String.t())
  def used_keys(site_id) do
    @sources
    |> Enum.flat_map(&asked(&1, usage(site_id)))
    |> Enum.flat_map(fn {_site_id, keys} -> keys end)
    |> MapSet.new()
  end

  @doc """
  Registers what the components, pages and layouts in `scope` ask for (`source_keys/1`), each key
  under its OWN record's site — exactly what saving each of them would have done. The backfill for
  records written before `t/1` existed, or before a site gained a language.

  `scope` is a site id, `nil` for the global templates, or `:all`.
  """
  @spec sync(String.t() | nil | :all) :: :ok
  def sync(scope) do
    @sources
    |> Enum.flat_map(&asked(&1, scope))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {site_id, keys} ->
      register(site_id, keys |> Enum.concat() |> Enum.uniq())
    end)
  end

  @doc """
  Deletes the rows in `scope` that no component, page or layout asks for any more (`used_keys/1`),
  as `actor`. For a site admin, `:all` and their own site both mean their own site, and any other
  scope deletes nothing. Returns how many went, and the cache forgets them at once, so a key asked for again renders itself rather
  than the word that was deleted.

  Obsolete rows are kept until someone asks for this, deliberately: deleting throws away a
  translation somebody wrote, and a renamed key is often renamed back.
  """
  @spec purge_unused(map(), String.t() | nil | :all) :: non_neg_integer()
  def purge_unused(actor, scope) do
    case writable(actor, scope) do
      :none -> 0
      scope -> purge(actor, scope)
    end
  end

  defp purge(actor, scope), do: scope |> unused_rows() |> destroy(actor)

  @doc """
  The ids of the rows `purge_unused/2` would delete for `actor` in `scope` — what **Remove unused**
  lists before anything is deleted.
  """
  @spec unused_ids(map(), String.t() | nil | :all) :: [String.t()]
  def unused_ids(actor, scope) do
    case writable(actor, scope) do
      :none -> []
      scope -> scope |> unused_rows() |> Enum.map(& &1.id)
    end
  end

  defp unused_rows(scope) do
    rows =
      Translation
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> within(scope)
      |> Ash.Query.select([:id, :site_id, :key, :language])
      |> Ash.stream!(authorize?: false)
      |> Enum.to_list()

    used = rows |> Enum.map(& &1.site_id) |> Enum.uniq() |> Map.new(&{&1, used_keys(&1)})
    Enum.reject(rows, &MapSet.member?(Map.fetch!(used, &1.site_id), &1.key))
  end

  @doc """
  Deletes the key the row `id` belongs to, in every language, as `actor` — what Delete means on a
  row of the admin list, which stands for the key rather than for one of its languages. Returns how
  many rows went; the cache forgets each of them.
  """
  @spec delete_key(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def delete_key(actor, id) do
    with {:ok, row} <- get(actor, id),
         do: {:ok, row.key |> rows_of(row.site_id) |> destroy(actor)}
  end

  @doc """
  The key the row `id` belongs to, in every language, for the translate modal:
  `%{key, site_id, rows: [%{id, language, value}]}`.

  A language `languages/1` names that has no row yet — the site gained it after the key was
  registered — is registered first where `actor` may write, so the modal can offer it. Read as
  `actor`: a row they may not read is `{:error, :not_found}`, as it would be in the table.
  """
  @spec group(map(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def group(actor, id) do
    with {:ok, row} <- get(actor, id) do
      if may_write?(actor, row.site_id), do: register(row.site_id, [row.key])

      order = row.site_id |> languages() |> Enum.with_index() |> Map.new()

      rows =
        row.key
        |> rows_of(row.site_id)
        |> Enum.sort_by(&{Map.get(order, &1.language, map_size(order)), &1.language})
        |> Enum.map(&Map.take(&1, [:id, :language, :value]))

      {:ok, %{key: row.key, site_id: row.site_id, rows: rows}}
    end
  end

  @doc """
  Gives the word `key` on `site_id` a row in `language`, as `actor` — publishing the language on the
  site first when the site does not publish it yet, by adding it to that site's `site.languages`
  (the global list, for a global word).

  Held to the same line as every other write here: a master may add to any site or to the global
  list; a site admin to their own site alone, never the global list. And to the master's bounds: a
  language outside `Languages.allowed/0` is refused, as the settings page refuses it.
  """
  @spec add_language(map(), String.t() | nil, String.t(), String.t()) ::
          :ok | {:error, :forbidden | :not_allowed | :invalid}
  def add_language(actor, site_id, key, language) do
    code = language |> to_string() |> String.trim() |> String.downcase()

    cond do
      not may_write?(actor, site_id) -> {:error, :forbidden}
      code in languages(site_id) -> register(site_id, [key])
      not Languages.valid?([code]) -> {:error, refusal(code)}
      true -> publish(actor, site_id, key, code)
    end
  end

  @doc """
  The languages `add_language/4` could still give the word whose rows are `held`: the master's
  allowed ones, else every language a site publishes — either way, less the ones it already has.
  """
  @spec addable_languages([String.t()]) :: [String.t()]
  def addable_languages(held) do
    case Languages.allowed() do
      [] -> languages(nil) -- held
      allowed -> allowed -- held
    end
  end

  defp publish(actor, site_id, key, code) do
    case Settings.put_as(actor, "site.languages", Languages.site(site_id) ++ [code],
           site_id: site_id
         ) do
      {:ok, _stored} -> register(site_id, [key])
      {:error, _refused} -> {:error, :forbidden}
    end
  end

  @doc """
  Whether `actor` may write `site_id`'s words — a holder of the translation area
  (`admin:dashboard:runtime:translation`): a master anywhere, a site admin on their own site and never the
  global rows. The line `add_language/4`, `group/2` and `purge_unused/2` all hold.
  """
  @spec may_write?(map(), String.t() | nil) :: boolean()
  def may_write?(actor, site_id), do: writable(actor, site_id) != :none

  # Shaped like a code yet refused by `valid?/1` means the master does not allow it.
  defp refusal(code),
    do: if(Languages.codes_or_empty?([code]), do: :not_allowed, else: :invalid)

  # ONE ROW STANDS FOR ITS KEY, AMONG THE ROWS THE FILTERS KEPT: the one in the first language by
  # code. With no filter that is the key's first language; filtered to FA and FR it is the FA row, so a
  # word shows once whatever is picked — listing a row per matching language would draw the same word
  # twice. Every row of a key shares its site, so whoever may read one may read them all.
  #
  # A fragment and not a relationship: Ash would carry the viewer's tenant into the subquery, and a
  # site admin's global keys would each show once per language. Its two narrowings repeat the table's
  # own filters exactly — `language IN` for the Language filter, and for the search what Gervaz's
  # `:text` filter compiles to over the `:search` filter's fields: `ILIKE` on a `%…%` pattern whose
  # `\`, `%` and `_` are escaped, ash_sql's `escape_contains/1`.
  @doc """
  The admin list's `on_load`: one row per key and site, among the rows its filters kept, whose
  chips show every language of it.
  """
  @spec one_row_per_key(Ash.Query.t(), map()) :: Ash.Query.t()
  def one_row_per_key(query, state) do
    %{languages: languages, term: term} = listing(state)
    pattern = term && contains_pattern(term)

    Ash.Query.filter(
      query,
      fragment(
        "NOT EXISTS (SELECT 1 FROM cms_translations AS other WHERE other.key = ? AND other.site_id IS NOT DISTINCT FROM ? AND other.language < ? AND (cardinality(?::text[]) = 0 OR other.language = ANY(?::text[])) AND (?::text IS NULL OR other.key ILIKE ?::text OR other.value ILIKE ?::text))",
        key,
        site_id,
        language,
        ^languages,
        ^languages,
        ^pattern,
        ^pattern,
        ^pattern
      )
    )
  end

  defp contains_pattern(term), do: "%" <> String.replace(term, ~r/([\\%_])/u, "\\\\\\0") <> "%"

  @doc """
  The admin list's `on_realtime`: a change to any language of a key redraws the row standing for it
  under the list's filters — read again, so its chips hold the change — and takes out the changed row
  when it is not that one, so a save never adds a second row for the same word. A word new to the list
  comes first, as a new row does in every other realtime list, and the list's total is read again.
  """
  @spec on_realtime(Ash.Notifier.Notification.t(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_realtime(%{data: %Translation{} = row}, socket) do
    state = socket.assigns.table_state

    {:halt,
     socket
     |> redraw_key(state, row)
     |> DataLoader.refresh_total()}
  end

  def on_realtime(_notification, socket), do: {:cont, socket}

  # THE ROW STANDING FOR A WORD CAN CHANGE HANDS: a language added that sorts first — `de` before
  # `en` — becomes it. So every other row of the word leaves the stream, not only the one the
  # notification named, and the one standing for it now is read again and put in: at the top when
  # the list did not show it, where it stands when it did — and only if the table's own read, its
  # `path_params` included, returns it.
  defp redraw_key(socket, state, row) do
    stream = state.static.stream_name
    first = first_row_id(row.key, row.site_id, listing(state))

    socket =
      row.key
      |> rows_of(row.site_id)
      |> Enum.map(& &1.id)
      |> then(&[row.id | &1])
      |> Enum.uniq()
      |> Enum.reject(&(&1 == first))
      |> Enum.reduce(socket, &Phoenix.LiveView.stream_delete(&2, stream, %Translation{id: &1}))

    with id when is_binary(id) <- first,
         true <- DataLoader.in_view?(state, id),
         %Translation{} = standing <- Events.get_record(state, id, :active) do
      Phoenix.LiveView.stream_insert(socket, stream, standing, at: 0)
    else
      _left_out -> socket
    end
  end

  # The same row `one_row_per_key/2` keeps, found in Ash's own terms.
  defp first_row_id(key, site_id, %{languages: languages, term: term}) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key == ^key)
    |> within_site(site_id)
    |> then(&if(languages == [], do: &1, else: Ash.Query.filter(&1, language in ^languages)))
    |> then(
      &if(is_nil(term),
        do: &1,
        else:
          Ash.Query.filter(
            &1,
            contains(key, ^Ash.CiString.new(term)) or contains(value, ^Ash.CiString.new(term))
          )
      )
    )
    |> Ash.Query.sort(language: :asc)
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, page: false)
    |> case do
      nil -> nil
      %{id: id} -> id
    end
  end

  # What the list is filtered by, as the table holds it: the Language filter's codes, and the search
  # term — both empty when unset.
  defp listing(%{filter_values: values}) when is_map(values) do
    %{
      languages:
        values
        |> Map.get(:language)
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 in ["", "__nil__"])),
      term:
        case MishkaGervaz.Table.Types.Filter.Text.parse_value(Map.get(values, :search), %{}) do
          term when is_binary(term) and term != "" -> term
          _none -> nil
        end
    }
  end

  defp listing(_state), do: %{languages: [], term: nil}

  defp rows_of(key, site_id) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key == ^key)
    |> within_site(site_id)
    |> Ash.read!(authorize?: false, page: false)
  end

  defp within_site(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp within_site(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  # AS THE VIEWER, through the table's own get: a row they may not read is not found.
  defp get(actor, id) do
    case Ash.get(Translation, id,
           action: get_action(actor),
           actor: actor,
           tenant: actor_tenant(actor),
           error?: false
         ) do
      {:ok, %Translation{} = row} -> {:ok, row}
      _missing_or_refused -> {:error, :not_found}
    end
  end

  # Row by row as `actor`, so a row the policies refuse stays; the cache forgets the rest.
  defp destroy([], _actor), do: 0

  defp destroy(rows, actor) do
    %Ash.BulkResult{records: gone} =
      Ash.bulk_destroy(rows, destroy_action(actor), %{},
        actor: actor,
        tenant: actor_tenant(actor),
        return_records?: true,
        strategy: [:stream],
        return_errors?: true,
        stop_on_error?: false,
        notify?: true
      )

    length(gone || [])
  end

  @doc """
  The languages a row for `site_id` is registered in and may be written in.

  A site's row takes the site's own list. A global row takes every language any site publishes in,
  and the global list besides: it serves every site, so a global component rendered on a Persian
  site asks for Persian whatever the global list says.

  Read from the sites' own settings, not from the translations — a language nobody has translated
  into yet has no cached value to be found by. Two ETS reads per site, no query.

      Translations.languages(site_id) #=> ["en", "fa"]
      Translations.languages(nil)     #=> ["de", "en", "fa"]
  """
  @spec languages(String.t() | nil) :: [String.t()]
  def languages(nil) do
    SiteState.stream()
    |> Enum.flat_map(&Languages.site(&1.id))
    |> Enum.concat(Languages.site(nil))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def languages(site_id), do: Languages.site(site_id)

  @doc "`languages(nil)` as the admin's pickers want it: `{\"FA\", \"fa\"}`."
  @spec language_options() :: [{String.t(), String.t()}]
  def language_options, do: options(languages(nil))

  @doc """
  The languages the Add form offers, from the form's own state: a master's picked site's, every
  site's for Global (`"__nil__"`, Gervaz's nil option), nothing until a site is picked; a site
  admin's own site's, the site field being a master's alone.
  """
  @spec language_options_for(map()) :: [{String.t(), String.t()}]
  def language_options_for(%{master_user?: true} = state) do
    case get_in(state, [Access.key(:field_values, %{}), :site_id]) do
      unpicked when unpicked in [nil, ""] -> []
      "__nil__" -> options(languages(nil))
      site_id -> options(languages(site_id))
    end
  end

  def language_options_for(%{current_user: %{site_id: site_id}}) when is_binary(site_id),
    do: options(languages(site_id))

  def language_options_for(_state), do: []

  defp options(languages), do: Enum.map(languages, &{String.upcase(&1), &1})

  @doc """
  An Ash validation: the language is one of `languages/1` for the row's site.

  A translation into a language the site does not serve would never be rendered, and would be
  cached for nothing.
  """
  @spec published_language(Ash.Changeset.t(), map()) :: :ok | {:error, keyword()}
  def published_language(changeset, context) do
    language = Ash.Changeset.get_attribute(changeset, :language)

    # THE TENANT, WHEN THE ROW DOES NOT NAME A SITE YET. A tenant `:create` runs this before the change
    # that stamps `site_id`, so the row says nothing; and the context is an
    # `Ash.Resource.Validation.Context` struct, which has a `tenant` field and no Access.
    site_id = Ash.Changeset.get_attribute(changeset, :site_id) || context.tenant

    if language in languages(site_id),
      do: :ok,
      else:
        {:error,
         field: :language,
         message: dgettext_noop("errors", "is not a language this site publishes in")}
  end

  # AN ESCAPE IS READ THE WAY THE COMPILER WILL READ IT. `t("Say \"hi\"")` asks for `Say "hi"` at
  # render, so that is the key it registers. `Code.string_to_quoted/1` parses the literal — it does
  # not evaluate anything — and an interpolated one comes back as an expression, not a binary: it
  # names no fixed key, so it is skipped.
  defp literal(literal) do
    if String.contains?(literal, ["\\", "\#{"]) do
      case Code.string_to_quoted(~s("#{literal}")) do
        {:ok, key} when is_binary(key) and key != "" -> [key]
        _dynamic_or_broken -> []
      end
    else
      if literal == "", do: [], else: [literal]
    end
  end

  defp interpolate(text, bindings) when bindings in [[], %{}], do: text

  defp interpolate(text, bindings) do
    Regex.replace(@placeholder, text, fn whole, name ->
      case Enum.find(bindings, fn {key, _value} -> to_string(key) == name end) do
        {_key, value} -> to_string(value)
        nil -> whole
      end
    end)
  end

  defp asked(resource, scope) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> within(scope)
    |> Ash.Query.select([:site_id | source_fields(resource)])
    |> Ash.stream!(authorize?: false)
    |> Enum.map(&{&1.site_id, source_keys(&1)})
  end

  defp usage(nil), do: :all
  defp usage(site_id), do: {:with_globals, site_id}

  defp within(query, :all), do: query
  defp within(query, nil), do: Ash.Query.filter(query, is_nil(site_id))

  defp within(query, {:with_globals, site_id}),
    do: Ash.Query.filter(query, site_id == ^site_id or is_nil(site_id))

  defp within(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  # WHAT WAS ASKED FOR, NARROWED TO WHAT THE ACTOR MAY WRITE. Only a holder of the translation area
  # writes words at all. A master (`site_id` nil) writes what it asked for. A site admin's `:all` is
  # their own site, and so is their own site; the global rows and every other site are `:none` —
  # asked about site B, they purge nothing, rather than their own site in its place. No user, and
  # anything that is not one, writes nothing. Narrowing before the read means `bulk_destroy/4` is
  # never handed a row the policies would refuse.
  defp writable(actor, scope) do
    case AccessPermissions.match?(actor, %{},
           permissions: ["admin:dashboard:runtime:translation"]
         ) do
      true -> within_reach(actor, scope)
      false -> :none
    end
  end

  defp within_reach(%{site_id: nil}, scope), do: scope

  defp within_reach(%{site_id: own}, scope)
       when is_binary(own) and (scope == :all or scope == own),
       do: own

  defp within_reach(_not_a_master, _scope), do: :none

  defp destroy_action(%{site_id: nil}), do: :master_destroy
  defp destroy_action(_actor), do: :destroy

  defp get_action(%{site_id: nil}), do: :master_get
  defp get_action(_actor), do: :tenant_get

  defp actor_tenant(%{site_id: site_id}), do: site_id
  defp actor_tenant(_actor), do: nil
end
