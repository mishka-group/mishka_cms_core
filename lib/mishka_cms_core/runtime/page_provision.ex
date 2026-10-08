defmodule MishkaCmsCore.Runtime.PageProvision do
  @moduledoc """
  Pages a site is GIVEN rather than written by hand — an extension provisioning itself, the dev
  seeds — and the one question every one of those callers has to ask before it writes a row: is
  this page already somebody's?

  ## Why the question is not "is this path taken"

  `MishkaCmsCore.Runtime.Page` is unique by more than its address. `unique_name_per_site` refuses a
  second page called `blog` however different its path, so a site the dev seeds touched — each of
  them has a page named "Blog" at `/blog` — refused the blog extension's first sample page at a
  path nothing had taken. Left to `Ash.create!` that is a raise in the MIDDLE of a run: the
  definitions after it are never written, whatever the caller does after the pages is never
  reached, and every later run stops at the same row, so the site stays half-provisioned for good
  and the admin who pressed the button is told only that it failed.

  ## Every identity, including the one added after this was written

  `missing/3` reads the identities off the resource and asks about each of them, so a page is left
  alone when ANY of them is held and the rest of the run happens regardless. Nothing here names
  `:name` or `:path`: the day a third unique constraint is added to the resource, it is checked.

  Two kinds of identity are not asked about:

    * one keyed on a value the row only gets when it is written — `preview_token` is minted inside
      the create action, `language_group_id` by a before-action change — because the caller cannot
      say what to look for;
    * one keyed on a `nil` of ours that it counts as distinct, which cannot collide with anything.

  `create/2` is where the first kind is caught, and with it the row another run wrote in between:
  a create refused by a unique index is read as the page being taken and reported as a skip, and so
  is one refused because another page answers at its public address
  (`MishkaCmsCore.Runtime.Resources.Validations.PublicAddress`) — `/:lang/blog` on a site whose
  `/blog` is a page of its own. Every other error is raised, because a template that does not
  compile is not a page somebody already has.

  ## A held NAME is not a held address

  The two are not the same answer and used to get the same one. An address is what the page IS — a
  reader types it, a component links to it, and a site that answers there answers with whatever is
  there already — so a held `path` is a real skip. A name is only how an admin finds the page in a
  list, and every dev-seeded site here holds `blog` at `/blog`: the one page that carries the blog's
  index was therefore skipped on every seeded site, at an address nothing had taken, and no later
  run was ever going to write it.

  So a definition whose ONLY held identities are keyed on `:name` is written under the next free
  name — `Blog 2`, `Blog 3` — and `create/2` reports it under `renamed`, which is the other half:
  a page that quietly appears under a name nobody asked for is as bad as one that never appears.
  `@name_attempts` bounds the search, and a definition that runs out of names is skipped the way it
  was before. Any other identity being held is still a skip, because nothing here can say what
  would free it.

  ## The two calls, and why they are two

  Callers ask what is missing, then write it:

      site_id
      |> PageProvision.missing(definitions)
      |> PageProvision.create(&write_page!/1)

  `MishkaCmsCore.Dev.Seeds` is why the plan is handed back rather than kept inside: it builds a
  layout for its pages, and only when there is a page to hang on one — a layout made on every run
  is the one thing a reseed used to leave growing behind it.

  A definition is the attribute map the create will take, which is what makes the comparison
  honest: the values looked for are the values that will be written, with the action's own
  `slugify` changes applied the way the row will carry them. Attributes the caller leaves to the
  create are the ones this cannot ask about.

  Both calls report in the same shape. `note/1` turns one skipped page — or one written under
  another name — into the line a dashboard shows an admin, and `answered?/1` says which kind of skip
  it was: a page the site already answers at, or one nothing is ever going to write.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  import Ash.Expr

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Page

  # The page size of the reads below, not how much of them is read: `every_page/1` reads all of it.
  @row_limit 100

  # HOW FAR A DEFINITION LOOKS FOR A NAME OF ITS OWN before it gives up and is skipped. A site
  # holding twenty pages named after one of these has something going on that a provisioner should
  # not answer by writing a twenty-first.
  @name_attempts 20

  @typedoc "The attributes a page create is given, as the caller will hand them to it."
  @type attrs :: %{optional(atom()) => term()}

  @typedoc """
  A page nothing holds yet, with the values its row will carry. `renamed` is the identity something
  else holds under the name the definition asked for, and `nil` where it got the name it asked for.
  """
  @type writable :: %{
          attrs: attrs(),
          values: %{optional(atom()) => term()},
          renamed: keyword() | nil
        }

  @typedoc """
  A page left alone: the address it would have answered at, and the key-value pairs of every
  identity something already there holds. The attributes themselves are not carried — a page's
  template is most of it, and this is what a report is written from.
  """
  @type held :: %{path: String.t(), fields: keyword(), ours?: boolean()}

  @typedoc """
  A page written under a name of its own: its address, the name its row carries, and the identity
  something else holds under the name it asked for.
  """
  @type renamed :: %{path: String.t(), name: String.t(), fields: keyword()}

  @type plan :: {[writable()], [held()]}

  @type report :: %{created: [attrs()], renamed: [renamed()], skipped: [held()]}

  # WHO GAVE THE SITE THIS PAGE, written into `extra` on the way in. A component says where it came
  # from — `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` stamps `ui_kit` and `ui_kit_version`, which
  # is how an upgrade tells a row it may replace from one an admin has edited — and a page said
  # nothing at all. Its only mark was `section`, an ordinary string the author is free to retype.
  #
  # An installer cannot work without the answer: "this site already has a page at /blog" is true of
  # the blog's own page and of one the admin built, and the two want opposite things said about them.
  @source_key "provisioned_by"
  @version_key "provisioned_version"

  # A PAGE WHOSE CONTENT IS NOT WRITTEN IN A LANGUAGE AT ALL. `/:lang/blog` holds no prose: it holds
  # components that read the captured language and fetch that language's rows, so one page answers
  # every language a site publishes and duplicating it would duplicate nothing. It is not an
  # untranslated page — there is nothing in it to translate.
  #
  # `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState` reads this: a routing row with no language
  # answers whichever the URL captured, while a row that names one answers only that one. Without the
  # mark a static English page and a component-driven one are the same row to the router, and the
  # rule that keeps `/fa/about` from serving English would take `/fa/blog` down with it.
  @any_language_key "serves_all_languages"

  @doc """
  The attributes with a mark saying which extension gave the site this page, and at what version.

  `source` is the extension's OTP app — `:mishka_blog` — and `version` the bundle version it was
  written against. Both go into `extra`, beside whatever the definition already put there.

      PageProvision.stamp(attrs, :mishka_blog, "3.0.1")

  Pass it through `missing/3`'s `:stamp` option rather than calling it per page; that way every
  definition in a run is marked the same way and a caller cannot mark half of them.
  """
  @spec stamp(attrs(), atom() | String.t(), String.t() | nil) :: attrs()
  def stamp(attrs, source, version) do
    extra =
      attrs
      |> Map.get(:extra, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.put(@source_key, to_string(source))
      |> Map.put(@version_key, version)

    Map.put(attrs, :extra, extra)
  end

  @doc """
  Which extension gave the site this page, as the string `stamp/3` wrote, or `nil` for a page
  nothing marked — one written by hand, or provisioned before pages were stamped.

  `nil` is not "not ours". It is "nothing here says", and a caller deciding whether it may touch a
  row has to treat the two differently: an unmarked page at the address we wanted is the admin's
  until they say otherwise.
  """
  @spec provisioned_by(map()) :: String.t() | nil
  def provisioned_by(%{extra: extra}) when is_map(extra), do: string(Map.get(extra, @source_key))
  def provisioned_by(_row), do: nil

  @doc """
  Whether this page answers every language its site publishes, rather than one.

  True of a page built from components that read the captured language — the blog's index, a
  document's section — and false of one whose template holds prose, which answers the language it
  was written in and leaves the others to editions of their own.

  The mark is read under the string key a row stores and under the atom a compiled page's `extra`
  carries once `MishkaCmsCore.Runtime.Helpers.atomize_keys/1` has converted it.
  """
  @spec serves_all_languages?(map()) :: boolean()
  def serves_all_languages?(%{extra: extra}) when is_map(extra),
    do: Map.get(extra, @any_language_key, Map.get(extra, :serves_all_languages)) == true

  def serves_all_languages?(_no_extra), do: false

  @doc """
  The language a page's routing row carries: none for a page that `serves_all_languages?/1`, else
  its own. `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState` reads `nil` as "answers whichever
  language the URL captured".

  The boot pass and the worker that runs after every save both ask this. Decided in each of them,
  the two disagreed: `/fa/blog` answered after a restart and 404ed after the page was edited.
  """
  @spec routing_language(map()) :: String.t() | nil
  def routing_language(page) do
    if serves_all_languages?(page), do: nil, else: Map.get(page, :language)
  end

  @doc """
  Marks `attrs` as a page that answers every language — see `serves_all_languages?/1` — when its
  `:path` captures `lang`, and clears the mark when it does not: only a `lang` capture can answer
  more than one language, and a page refuses the mark on any other path.
  """
  @spec serving_all_languages(map()) :: map()
  def serving_all_languages(attrs) do
    extra = attrs |> Map.get(:extra, %{}) |> then(&if(is_map(&1), do: &1, else: %{}))

    extra =
      if Languages.captures?(Map.get(attrs, :path)),
        do: Map.put(extra, @any_language_key, true),
        else: Map.delete(extra, @any_language_key)

    Map.put(attrs, :extra, extra)
  end

  @doc "The version `stamp/3` recorded, or `nil`. See `provisioned_by/1` about `nil`."
  @spec provisioned_version(map()) :: String.t() | nil
  def provisioned_version(%{extra: extra}) when is_map(extra),
    do: string(Map.get(extra, @version_key))

  def provisioned_version(_row), do: nil

  @doc """
  Whether `source` is what gave the site this page — `false` for a page nothing marked.

      PageProvision.ours?(page, :mishka_blog)
  """
  @spec ours?(map(), atom() | String.t()) :: boolean()
  def ours?(row, source), do: provisioned_by(row) == to_string(source)

  defp string(value) when is_binary(value), do: value
  defp string(_other), do: nil

  @doc """
  Splits `definitions` into the pages `site_id` can still be given and the ones something already
  holds — the first group carrying the name each page will actually be written under.

  `definitions` are attribute maps for a page create; `site_id` is the site they are for, whether
  or not they name it themselves. Pass `action: :create` when the write goes through the tenant
  action rather than `:master_create`, so the attributes are compared as that action stores them.

  Pass `actor: user` and the reads are made as that user, so the page resource's own policy answers
  for them. Leave it out — the wizard, which runs before there is a user, and the seeds, which have
  no session — and they are made as the system.

  Pass `stamp: {:mishka_blog, "3.0.1"}` — or just `stamp: :mishka_blog` — and every page written
  from this plan says which extension gave it to the site. See `stamp/3`, and `provisioned_by/1`
  for reading it back. A provisioner that writes pages should always pass it; without it its pages
  are indistinguishable from the admin's own.
  """
  @spec missing(String.t(), [attrs()], keyword()) :: plan()
  def missing(site_id, definitions, opts \\ [])
      when is_binary(site_id) and is_list(definitions) do
    slugifiers =
      Page
      |> Ash.Resource.Info.action(Keyword.get(opts, :action, :master_create))
      |> slugifiers()

    marked = Enum.map(definitions, &marked(&1, Keyword.get(opts, :stamp)))

    planned =
      Enum.map(marked, fn attrs ->
        values = attrs |> Map.put(:site_id, site_id) |> stored(slugifiers)

        {attrs, values, checks(values)}
      end)

    actor = Keyword.get(opts, :actor)

    rows =
      rows_holding(
        for({_attrs, _values, checks} <- planned, fields <- checks, do: fields),
        actor
      )

    source = stamp_source(Keyword.get(opts, :stamp))

    planned
    |> Enum.map(&verdict(&1, rows, source))
    |> settle(slugifiers, actor)
  end

  @doc """
  Writes each page of a `missing/3` plan with `write`, and returns `%{created: attrs,
  renamed: renamed, skipped: held}` — the skipped ones being the plan's own plus any the database
  refused, and the renamed ones those written under a name the definition did not ask for.

  `write` is given one attribute map and is expected to raise on failure, which `Ash.create!` does.
  """
  @spec create(plan(), (attrs() -> any())) :: report()
  def create({writable, held}, write) when is_list(writable) and is_function(write, 1) do
    {created, renamed, refused} =
      Enum.reduce(writable, {[], [], []}, fn entry, {created, renamed, refused} ->
        try do
          write.(entry.attrs)

          {[entry.attrs | created], renaming(entry, renamed), refused}
        rescue
          error ->
            case refusal(error, entry.values) do
              nil ->
                reraise error, __STACKTRACE__

              fields ->
                {created, renamed, [%{path: entry.attrs[:path], fields: fields} | refused]}
            end
        end
      end)

    %{
      created: Enum.reverse(created),
      renamed: Enum.reverse(renamed),
      skipped: held ++ Enum.reverse(refused)
    }
  end

  @doc """
  One line saying what a run left alone and why, or what it had to call a page whose own name was
  taken, for a page that has to tell somebody — an admin reading a dashboard, a developer reading a
  seed run.
  """
  @spec note(held() | renamed()) :: String.t()
  def note(%{path: path, name: name, fields: fields}) do
    gettext("%{path} — %{reason}, so it was created as %{name}",
      path: path,
      reason: because(Keyword.delete(fields, :site_id)),
      name: inspect(name)
    )
  end

  def note(%{path: path, fields: fields}) do
    gettext("%{path} — %{reason}", path: path, reason: because(Keyword.delete(fields, :site_id)))
  end

  @doc """
  Whether the site answers at the address the skipped page would have had.

  THE TWO KINDS OF SKIP ARE NOT ONE THING, and every report made of them has to tell them apart: a
  page left alone because its own row is already there is the ordinary case of a run repeated,
  while one whose NAME a DIFFERENT page holds was never written and no later run will write it.
  Told that the second is "already there", whoever reads the report is told the opposite of what
  happened.
  """
  @spec answered?(held()) :: boolean()
  def answered?(%{path: path, fields: fields}),
    do: Keyword.get(fields, :path) == path or Keyword.has_key?(fields, :answered_at)

  # THE SITE IS NOT NEWS. Every identity but the global ones is keyed on it, and a line telling an
  # admin the site they chose is already the site they chose says nothing.
  defp because([]), do: gettext("something the site already has holds it")

  defp because(fields) do
    fields
    |> Enum.map(fn {key, value} -> taken_phrase(key, inspect(value)) end)
    |> Enum.reduce(fn next, joined ->
      gettext("%{joined} and %{next}", joined: joined, next: next)
    end)
  end

  defp taken_phrase(:name, value), do: gettext("its name %{value} is taken", value: value)
  defp taken_phrase(:path, value), do: gettext("its path %{value} is taken", value: value)
  defp taken_phrase(:language, value), do: gettext("its language %{value} is taken", value: value)

  defp taken_phrase(:answered_at, value),
    do: gettext("another page already answers at its address %{value}", value: value)

  defp taken_phrase(key, value),
    do: gettext("its %{field} %{value} is taken", field: key, value: value)

  defp renaming(%{renamed: nil}, renamed), do: renamed

  defp renaming(entry, renamed),
    do: [
      %{path: entry.attrs[:path], name: entry.values[:name], fields: entry.renamed} | renamed
    ]

  # ---------------------------------------------------------------------------
  # Whose page it is, and which name is left
  # ---------------------------------------------------------------------------

  # EVERY DEFINITION IN A RUN, OR NONE. `:stamp` is read once here rather than by each caller, so a
  # provisioner cannot mark some of its pages and leave others looking like the admin's.
  defp stamp_source({source, _version}), do: source
  defp stamp_source(source) when is_atom(source) or is_binary(source), do: source
  defp stamp_source(_none), do: nil

  defp marked(attrs, nil), do: attrs
  defp marked(attrs, {source, version}), do: stamp(attrs, source, version)
  defp marked(attrs, source), do: stamp(attrs, source, nil)

  defp verdict({attrs, values, checks}, rows, source) do
    case Enum.filter(checks, &holder(rows, &1)) do
      [] -> {:free, attrs, values}
      matched -> contested(attrs, values, matched, rows, source)
    end
  end

  # A NAME IS THE ONE IDENTITY A PROVISIONER MAY ANSWER WITH ANOTHER VALUE. An address is what the
  # page IS, so a held `path` is a page this run is not going to write; a name is how an admin finds
  # it in a list, and the next free one serves as well as the first. Every OTHER identity that is
  # held is a skip as well — this cannot say what value would free one, and a provisioner that
  # guessed would be writing over somebody's row on a hunch.
  defp contested(attrs, values, matched, rows, source) do
    if Enum.all?(matched, &Keyword.has_key?(&1, :name)) do
      {:rename, attrs, values, taken(matched)}
    else
      {:held,
       %{path: attrs[:path], fields: taken(matched), ours?: held_by_us?(rows, matched, source)}}
    end
  end

  # WHOSE ROW IS AT THAT ADDRESS. A run repeated finds its OWN page and has nothing to say about it;
  # a run that finds somebody else's has the one thing an admin must answer. The two look identical
  # from the identity alone, which is why a provisioned page carries `provisioned_by` — see
  # `stamp/3`. A page nothing marked is not ours: it was written by hand, or before pages were
  # marked at all, and either way it is not this run's to claim.
  defp held_by_us?(_rows, _matched, nil), do: false

  defp held_by_us?(rows, matched, source) do
    Enum.any?(rows, fn row ->
      Enum.any?(matched, fn fields ->
        Enum.all?(fields, fn {key, value} -> Map.get(row, key) == value end)
      end) and ours?(row, source)
    end)
  end

  # THE SECOND READ, and only when there is something to ask about: the names offered instead are
  # not in the first one, because they are chosen from what it answered. Every candidate of every
  # definition goes into it at once, the same way the first read asks about every definition at
  # once.
  defp settle(verdicts, slugifiers, actor) do
    offered = Enum.map(verdicts, &candidates(&1, slugifiers))

    rows =
      rows_holding(
        for(
          {:rename, _attrs, _values, _fields, candidates} <- offered,
          {_attrs, _values, checks} <- candidates,
          fields <- checks,
          do: fields
        ),
        actor
      )

    {writable, held, _claimed} =
      Enum.reduce(offered, {[], [], claimed(verdicts)}, &chosen(&1, rows, &2))

    {Enum.reverse(writable), Enum.reverse(held)}
  end

  # THE NAMES THIS RUN IS ABOUT TO TAKE, which no read can see: two definitions of one bundle can
  # want the same name, and the second would be offered a name the first is on its way to writing.
  defp claimed(verdicts),
    do: MapSet.new(for {:free, _attrs, values} <- verdicts, do: values[:name])

  # ONLY THE CHECKS KEYED ON THE NAME, because the rest were answered by the first read and a
  # candidate changes none of them: a definition only gets here with every other identity free.
  defp candidates({:rename, attrs, values, fields}, slugifiers) do
    offered =
      Enum.map(2..@name_attempts, fn step ->
        wanted = Map.put(attrs, :name, "#{attrs[:name]} #{step}")
        stored = wanted |> Map.put(:site_id, values[:site_id]) |> stored(slugifiers)

        {wanted, stored, Enum.filter(checks(stored), &Keyword.has_key?(&1, :name))}
      end)

    {:rename, attrs, values, fields, offered}
  end

  defp candidates(verdict, _slugifiers), do: verdict

  defp chosen({:free, attrs, values}, _rows, {writable, held, claimed}),
    do: {[%{attrs: attrs, values: values, renamed: nil} | writable], held, claimed}

  defp chosen({:held, entry}, _rows, {writable, held, claimed}),
    do: {writable, [entry | held], claimed}

  defp chosen({:rename, attrs, _values, fields, candidates}, rows, {writable, held, claimed}) do
    case Enum.find(candidates, &free?(&1, rows, claimed)) do
      nil ->
        {writable, [%{path: attrs[:path], fields: fields, ours?: false} | held], claimed}

      {wanted, stored, _checks} ->
        entry = %{attrs: wanted, values: stored, renamed: fields}

        {[entry | writable], held, MapSet.put(claimed, stored[:name])}
    end
  end

  defp free?({_attrs, stored, checks}, rows, claimed) do
    not MapSet.member?(claimed, stored[:name]) and not Enum.any?(checks, &holder(rows, &1))
  end

  # ---------------------------------------------------------------------------
  # What the row will carry
  # ---------------------------------------------------------------------------

  # NOT THE VALUES HANDED OVER — the ones the write leaves behind. `slugify(:name, into: :name)`
  # runs in a before-action hook, so "Blog post" reaches the table as `blog-post`, and a site whose
  # own page is called "BLOG" or "Blog Post" is already holding one of these names under a spelling
  # no comparison of the literals would catch.
  defp stored(values, slugifiers) do
    Enum.reduce(slugifiers, values, fn {from, into, opts}, stored ->
      case Map.fetch(stored, from) do
        {:ok, text} when is_binary(text) -> Map.put(stored, into, Slug.slugify(text, opts))
        _nothing_to_slugify -> stored
      end
    end)
  end

  # READ OFF THE ACTION, not named here, so a second slugified attribute is compared as a slug the
  # day one is added — and through the change's own `init/1`, because the options are stored as they
  # were written and it is what turns them into the ones `Slug.slugify/2` takes.
  defp slugifiers(action) do
    action.changes
    |> Enum.filter(&match?(%{change: {AshSlug.Changes.Slugify, _opts}}, &1))
    |> Enum.map(fn %{change: {slugify, opts}} ->
      {:ok, ready} = slugify.init(opts)

      {ready[:attribute], ready[:into] || ready[:attribute],
       Keyword.drop(ready, [:attribute, :into])}
    end)
  end

  # ---------------------------------------------------------------------------
  # What is already there
  # ---------------------------------------------------------------------------

  # ONE CHECK PER IDENTITY THE ROW CAN BE LOOKED UP BY. An identity carrying a `where` is not one of
  # them: it holds only over the rows its filter admits, and this cannot say which those are.
  defp checks(values) do
    for identity <- Ash.Resource.Info.identities(Page),
        is_nil(identity.where),
        fields = fields(identity, values),
        is_list(fields),
        do: fields
  end

  defp fields(identity, values) do
    identity.keys
    |> Enum.reduce_while([], fn key, taken ->
      case Map.fetch(values, key) do
        :error ->
          {:halt, :not_ours_to_know}

        {:ok, nil} ->
          (identity.nils_distinct? && {:halt, :cannot_collide}) || {:cont, [{key, nil} | taken]}

        {:ok, value} ->
          {:cont, [{key, value} | taken]}
      end
    end)
    |> case do
      taken when is_list(taken) -> Enum.reverse(taken)
      why_not -> why_not
    end
  end

  # ONE READ PER ACTION FOR THE WHOLE RUN, not one per page: every check of every definition is
  # ORed into the same filter, and which row holds which page is worked out from what comes back.
  defp rows_holding(wanted, actor) do
    case Enum.uniq(wanted) do
      [] -> []
      asked_about -> read(asked_about, actor)
    end
  end

  defp read(wanted, actor) do
    filter = Enum.reduce(wanted, nil, fn fields, acc -> either(acc, conjunction(fields)) end)
    # `:extra` IS ALWAYS READ, because a held row has to say whose it is. That is the whole of
    # `ours?/1` below, and the difference between "this run has already been done" and "somebody
    # else is at that address".
    selected = wanted |> Enum.flat_map(&Keyword.keys/1) |> Enum.uniq() |> Enum.concat([:extra])

    # LIVE ROWS AND ARCHIVED ONES ALIKE, which is STRICTER than the database is. Every unique index
    # on this table is partial on the resource's own `base_filter_sql` — `(archived_at IS NULL)` —
    # so a page an admin archived would let the write through, leaving the site a second page under
    # a name it has already used and the archived one impossible to unarchive. Archiving a page is
    # an answer, not an absence.
    {archived, archived_opts} = archived_read(actor)

    for {action, opts} <- [{:read_any, reading(actor)}, {archived, archived_opts}],
        row <-
          Page
          |> Ash.Query.for_read(action, %{}, opts)
          |> Ash.Query.filter(^filter)
          |> Ash.Query.select(selected)
          |> rows(actor),
        uniq: true,
        do: row
  end

  # THE ARCHIVED ROWS, AND THE ONE READ AN ACTOR'S ROLE DOES CHANGE. `:master_archived` refuses a
  # tenant actor outright — see `MishkaCmsCore.Runtime.Resources.Validations.TenantContext` — so the
  # site's own admin reads its own `:archived` under its tenant, which answers with the same rows
  # for the only site they can be provisioning.
  defp archived_read(nil), do: {:master_archived, [authorize?: false]}
  defp archived_read(%{site_id: nil} = actor), do: {:master_archived, [actor: actor]}

  defp archived_read(%{site_id: site_id} = actor),
    do: {:archived, [actor: actor, tenant: site_id]}

  # WHO THIS READ IS FOR. A run with nobody behind it — the wizard, before there is a user; the
  # seeds, with no session at all — reads as the system, because there is nobody to read as.
  # Anybody else reads as themselves and the resource's own policy answers for them.
  #
  # THE ACTION STAYS `:read_any`, for a tenant admin as much as for a master. It bypasses
  # multitenancy, which is what lets one read cover the site a master chose, and every check names
  # `site_id` in the filter above, so the bypass widens nothing this run can see. The tenant read
  # cannot be swapped in here in any case: `:read` ships no `pagination`, and this pages through
  # every result on purpose — see `rows/2`.
  defp reading(nil), do: [authorize?: false]
  defp reading(actor), do: [actor: actor]

  defp conjunction(fields) do
    Enum.reduce(fields, nil, fn pair, acc -> both(acc, comparison(pair)) end)
  end

  # `field == ^nil` IS NOT `is_nil(field)`. `Ash.Query.Operator.Eq` answers nil for a nil side, which
  # reaches Postgres as `= NULL` and matches no row at all — so a key an identity counts nils on
  # would read as free however many rows hold it.
  defp comparison({key, nil}), do: expr(is_nil(^ref(key)))
  defp comparison({key, value}), do: expr(^ref(key) == ^value)

  defp both(nil, one), do: one
  defp both(acc, one), do: expr(^acc and ^one)

  defp either(nil, one), do: one
  defp either(acc, one), do: expr(^acc or ^one)

  defp holder(rows, fields) do
    Enum.any?(rows, fn row ->
      Enum.all?(fields, fn {key, value} -> Map.get(row, key) == value end)
    end) && fields
  end

  # EVERY IDENTITY THAT IS HELD, not the first one to be found held, because WHICH of them holds the
  # page is what `answered?/1` reads — and an answer that stopped at the first would turn on the
  # order the identities happen to be declared in. `site_id` is in most of them, so the pairs are
  # uniqued by key.
  defp taken(matched), do: matched |> Enum.concat() |> Enum.uniq_by(&elem(&1, 0))

  # EVERY PAGE OF RESULTS, not the first one. The unique indexes are partial on
  # `(archived_at IS NULL)`, so ONE name can hold any number of archived rows — and a read that
  # stopped at its first page would be filled by one name's discarded copies while the archived row
  # holding another name went unseen, and that page would be written back over what the admin threw
  # away. `MishkaCmsCore.Dev.Seeds` is where that was found, in its hooks.
  defp rows(query, actor) do
    query
    |> Ash.read!(reading(actor) ++ [page: [limit: @row_limit]])
    |> every_page()
  end

  # A PAGE THAT CARRIED SOMETHING is what earns the next one. `Ash.page/2` answers a keyset page
  # with no results with itself, so a page claiming `more?` over nothing would be asked for its
  # successor for ever; this clause cannot match it, and the read stops on whatever it has.
  defp every_page(%{results: [_first | _rest] = found, more?: true} = page),
    do: found ++ every_page(Ash.page!(page, :next))

  defp every_page(%{results: found}), do: found

  # ---------------------------------------------------------------------------
  # What the database said
  # ---------------------------------------------------------------------------

  # THE HALF OF THE ANSWER `missing/3` CANNOT READ: an identity keyed on a value the create itself
  # mints, and a row another run wrote between our read and this write. `constraint_type` is the
  # data layer saying a unique index refused the row, so nothing here reads an error message —
  # everything else raised is raised on, because a template that does not compile is not a page
  # somebody already has.
  defp refusal(%{errors: errors}, values) when is_list(errors) do
    Enum.find_value(errors, &unique_refusal(&1, values))
  end

  defp refusal(_not_a_refusal, _values), do: nil

  defp unique_refusal(%{private_vars: vars, field: field}, values) when is_list(vars) do
    case {Keyword.get(vars, :constraint_type), Map.fetch(values, field)} do
      {:unique, {:ok, value}} -> [{field, value}]
      {:unique, :error} -> []
      _not_a_unique_index -> nil
    end
  end

  # ANOTHER PAGE ANSWERS AT ITS PUBLIC ADDRESS — see
  # `MishkaCmsCore.Runtime.Resources.Validations.PublicAddress`. Its stored path is free, so no
  # identity says so; the refusal does.
  defp unique_refusal(%{field: :path, vars: vars}, _values) when is_list(vars) do
    case Keyword.get(vars, :answered_at) do
      address when is_binary(address) -> [answered_at: address]
      _other -> nil
    end
  end

  defp unique_refusal(_other_error, _values), do: nil
end
