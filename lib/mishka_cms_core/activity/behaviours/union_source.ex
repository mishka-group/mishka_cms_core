# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Behaviours.UnionSource do
  @moduledoc """
  A table of an extension's own merged into the activity log, as one more branch of the `UNION ALL`
  `MishkaCmsCore.Activity.Query` runs.

  The core's branches read what every installation has: AshPaperTrail versions, AshEvents logs, the
  runtime drafts and Oban jobs. A record that is none of those — the visual editor's history is the
  first — would never reach the log, so its owner contributes the branch. It registers on
  `activity:sources`, a collect event, through `MishkaCmsCore.ProviderRegistry`:

      use MishkaCmsCore.ProviderRegistry, event: "activity:sources", priority: 50
      @behaviour MishkaCmsCore.Activity.Behaviours.UnionSource

  With no source registered the log is the core's branches alone.

  ## The branch

  `union_branch/1` answers `{sql, params}` for one read, or `nil` when the read cannot reach any of
  its rows (a `warn` read of a table that only ever holds information, say), so its table is not
  scanned to return nothing. `sql` is one parenthesised `(SELECT … LIMIT $1)` selecting, in this
  order and with these types, the columns every branch selects:

      source text      -- the source's id/0, which is how its rows find entry_from_row/1 again
      resource text    -- the module name an entry is filed under ("Elixir.MishkaCmsCore.Runtime.Page")
      action text, source_id text, event_id text, site_id text, user_id text,
      inserted_at timestamp, payload jsonb

  It filters and orders itself, newest first, and caps itself at `$1`, so the merged top of the log
  is the top of each branch. The read's filters arrive as the shared positional parameters, which
  `MishkaCmsCore.Activity.Query`'s public clause builders write: `$1` the cap, `$4` the resource
  (`resource_clause/1`), `$5` the search (`search_clause/1`) and `$6` the tenant's site
  (`version_site_clause/2`, only when `site_id` is set); `shown_clause/2` and
  `content_severity_clause/2` narrow it by the viewer's resources and the read's severity.

  A value of the source's own is a parameter too, never text written into the SQL: `params` lists
  them, and the first is `$` followed by `first_param`, the next `first_param + 1`, and so on. Each
  is cast where it is used (`$7::text`), because Postgres must infer every parameter's type.

  ## Searching the sentence

  The search is matched in SQL, against the expressions the branch hands `search_clause/1`: a
  number, a title, a name. The sentence an entry reads as is built by `entry_from_row/1`, after the
  read, so a word of it ("published", "refunded") is in no column and finds nothing. A source that
  names its sentences in `sentences/0` gets them searched too: the read's `search_actions` are the
  actions whose words hold the search, and `MishkaCmsCore.Activity.Query.search_clause/3` keeps
  their rows beside the ones its expressions match:

      def sentences do
        [{"paid", gettext("Order paid")}, {"refunded", gettext("Order refunded")}]
      end

      # in the branch
      Query.search_clause(["o.number::text"], "o.kind", read.search_actions)

  An action is a plain name (letters, digits and `_`); any other is left out of the SQL.

  ## Its resources in the Resource filter

  The log's Resource filter lists the resources the core's branches discover. A source whose rows
  are filed under resources of its own names them in `resources/0`, as `{label, module_string}`,
  and they join the filter under their extension's group (`MishkaCmsCore.Activity.Query.resource_options/0`):

      def resources, do: [{"Order", "Elixir.MyShop.Order"}]

  Filing a row under a real resource module also decides who sees it: an admin who is not a full
  dashboard admin sees the rows of the resources whose areas their own policies ask for
  (`MishkaCmsCore.Activity.Helpers.resources_for/1`, the `shown` of the read).

  ## A link to the record

  An entry may carry `link`, a path of the same site (`"/admin/dashboard/shop/orders/1"`): the log
  draws its message as a link to it. Anything that is not a local path is dropped
  (`MishkaCmsCore.Activity.Helpers.local_path/1`), so a row can never send an admin to another host.

  ONE BROKEN BRANCH EMPTIES THE WHOLE LOG. The read is one query, so SQL that Postgres refuses fails
  every source with it, and the log answers "no matching events" (the failure is logged). A branch
  that raises or answers anything but `{sql, params}` is left out of the read on its own.

  ## New rows while the log is open

  The open Activity page reads the core's records live, but it cannot know when a source's table
  gains a row. A source tells it with `changed/1`, after the row is written, with the site the row
  belongs to (`nil` for a row of no site):

      MishkaCmsCore.Activity.Behaviours.UnionSource.changed(order.site_id)

  Every open log that may show that site's rows (its own site's, and every master's) reads its first
  page and its counts again, once for the changes that arrive together, so a burst of rows written in
  one go costs one read. The log keeps its filters, and a row the viewer may not see stays out, as
  on any read. The message is `{:activity_changed, site_id}` on `topic/1`; a page of its own may
  `subscribe/1` to it too.
  """

  alias MishkaCmsCore.Activity.Behaviours.Source
  alias MishkaCmsCore.Activity.Helpers
  alias MishkaCmsCore.ProviderRegistry

  @event "activity:sources"
  @topic "activity:changed"

  @typedoc """
  The read a branch is asked for. `site_id` is the one site read, `nil` for every site (a master);
  `severity` is `"info"`, `"warn"`, `"error"` or `nil`; `shown` is `:all` or the module strings
  the viewer may see; `first_param` is the position of the source's first own parameter;
  `search_actions` the actions whose sentence holds the words searched for (`search_actions/2`),
  `[]` when nothing is searched for or the source names no sentences.
  """
  @type read :: %{
          site_id: String.t() | nil,
          severity: String.t() | nil,
          shown: :all | [String.t()],
          first_param: pos_integer(),
          search_actions: [String.t()]
        }

  @doc "The value the branch writes in the `source` column: unique, and none of the core's own."
  @callback id() :: String.t()

  @doc "The branch for one read and its own parameters, or `nil` when the read reaches none of it."
  @callback union_branch(read()) :: {String.t(), [term()]} | nil

  @doc "One row the branch produced, as an entry of the log."
  @callback entry_from_row(map()) :: Source.entry()

  @doc "The resources its rows are filed under, as `{label, module_string}`, for the Resource filter."
  @callback resources() :: [{String.t(), String.t()}]

  @doc """
  The words each action's message says, as `{action, words}`: the value the branch's `action` column
  holds and its sentence without the record's own values, in the viewer's language (a `gettext`
  call), so a search for a word of the sentence finds the rows (see "Searching the sentence").
  """
  @callback sentences() :: [{String.t(), String.t()}]

  @optional_callbacks resources: 0, sentences: 0

  @doc "The event a union source registers on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The `MishkaCmsCore.PubSub` topic a log of `site_id`'s rows hears `{:activity_changed, site_id}` on;
  `nil` is every site's, the one a master's log hears.
  """
  @spec topic(String.t() | nil) :: String.t()
  def topic(nil), do: @topic
  def topic(site_id) when is_binary(site_id), do: @topic <> ":" <> site_id

  @doc """
  Subscribes the calling process to the topic of what `viewer` may see: every site's for a master,
  its own site's for a site user, and none for anyone else
  (`MishkaCmsCore.Activity.Helpers.reach/1`).
  """
  @spec subscribe(map() | nil) :: :ok | {:error, term()}
  def subscribe(viewer) do
    case Helpers.reach(viewer) do
      :everything -> Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic(nil))
      {:site, site_id} -> Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic(site_id))
      :nothing -> :ok
    end
  end

  @doc """
  Tells every open activity log that may show `site_id`'s rows that a source wrote new ones: the
  logs of that site and every master's log. Call it after the row is written (see "New rows while
  the log is open"); `nil` is a row of no site, which only a master's log shows.
  """
  @spec changed(String.t() | nil) :: :ok
  def changed(site_id) when is_binary(site_id) or is_nil(site_id) do
    for topic <- Enum.uniq([topic(site_id), topic(nil)]),
        do: Phoenix.PubSub.broadcast(MishkaCmsCore.PubSub, topic, {:activity_changed, site_id})

    :ok
  end

  @doc """
  The actions of `source` whose sentence (`sentences/0`) holds `search`, ignoring case and the
  spaces around it: the read's `search_actions`. `[]` for no search, a blank one, or a source that
  names no sentences.
  """
  @spec search_actions(module(), String.t() | nil) :: [String.t()]
  def search_actions(source, search) when is_binary(search) do
    with term when term != "" <- search |> String.trim() |> String.downcase(),
         true <- function_exported?(source, :sentences, 0) do
      for {action, words} <- List.wrap(source.sentences()),
          is_binary(action) and is_binary(words),
          String.contains?(String.downcase(words), term),
          uniq: true,
          do: action
    else
      _no_search -> []
    end
  end

  def search_actions(_source, _search), do: []

  @doc "Every union source installed, the first of each id."
  @spec all() :: [module()]
  def all, do: ProviderRegistry.all(@event, __MODULE__)

  @doc """
  The resources every installed source files its rows under (`resources/0`), as
  `{label, module_string}`; a source that names none, or answers anything else, adds nothing.
  """
  @spec resources([module()]) :: [{String.t(), String.t()}]
  def resources(sources \\ all()) do
    for source <- sources,
        function_exported?(source, :resources, 0),
        {label, module} <- List.wrap(source.resources()),
        is_binary(label) and is_binary(module),
        do: {label, module}
  end
end
