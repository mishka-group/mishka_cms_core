# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Query do
  @moduledoc """
  DB-side merge for the unified activity log. Builds one `UNION ALL` across every
  discovered AshPaperTrail version table, AshEvents event-log table, and the
  `oban_jobs` table, then lets Postgres do the filtering, ordering and pagination
  in a single round-trip — instead of fetching a wide window from each source and
  merging in memory.

  ## Why it is shaped this way (so indexes are actually usable)

  Every filter and the `ORDER BY … LIMIT` are pushed DOWN into each branch, and
  the branch caps itself at `offset + limit` rows. The global top-K can only come
  from each branch's own top-K, so merging the per-branch tops and re-sorting a
  tiny set is correct. This lets each branch use an index:

    * tenant scope is `site_id = $1::uuid` (raw uuid, NOT a text cast) so the
      `(site_id, version_inserted_at)` composite index is reachable;
    * `ORDER BY version_inserted_at DESC LIMIT k` rides that index (a bare
      `(version_inserted_at)` index serves the master path, where there is no
      site filter), instead of a Seq Scan + Sort over the whole table;
    * `kind` selects which branches run; `severity` is a branch-level predicate
      (and whole branches are skipped when they cannot match, e.g. version/event
      branches for `severity = "error"`).

  No `COUNT(*) OVER ()`: the `:load_more` table never needs an exact total
  (gervaz derives `more?` from Ash's page_size+1 extra row), and an exact count
  forces Postgres to materialise every matching row — defeating the early-LIMIT.
  `counts/1` is the deliberate exception — a separate, capped query for the page's
  KPI row, run off the render path, never joined onto `page/1`.

  Discovery is dynamic (`MishkaCmsCore.Activity.Discovery`): the query adapts to
  whatever extensions are installed, with no hardcoded resource or table names.
  Per-source presentation (label, message, badge, icon) is applied in Elixir over
  only the page's rows via each source's `entry_from_row/1`.

  See `MishkaCmsCore.Activity.ActivityEntry` (calls `page/1` from its manual read)
  and the source adapters `MishkaCmsCore.Activity.Sources.PaperTrail`,
  `MishkaCmsCore.Activity.Sources.EventLog`, `MishkaCmsCore.Activity.Sources.Oban`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Activity.{Discovery, Helpers}
  alias MishkaCmsCore.Activity.Sources.{EditorHistory, EventLog, Oban, RuntimeDraft, PaperTrail}

  require Logger

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # The runtime draft tables (Page/Layout/ErrorPage) merged into the unified log. `shared?` = the
  # table's `site_id` can be NULL (a global layout draft), so a tenant also sees global rows.
  @draft_tables [
    %{table: "page_drafts", module: "Elixir.MishkaCmsCore.Runtime.PageDraft", shared?: false},
    %{table: "layout_drafts", module: "Elixir.MishkaCmsCore.Runtime.LayoutDraft", shared?: true},
    %{
      table: "error_page_drafts",
      module: "Elixir.MishkaCmsCore.Runtime.ErrorPageDraft",
      shared?: false
    }
  ]

  @oban_table "oban_jobs"
  @warn_actions "'destroy','master_destroy','permanent_destroy','master_permanent_destroy'"
  @default_limit 20
  # Per-branch LIMIT ceiling so a crafted huge page can't make each branch scan unbounded.
  @max_cap 10_000

  @doc """
  Runs the unified activity query for one page and returns the entry maps (the
  `MishkaCmsCore.Activity.ActivityEntry` shape), already ordered newest-first.

  Opts:
    * `:site_id`  — the one site to read; `nil` reads every site, which only a master's reach
      asks for (`MishkaCmsCore.Activity.Helpers.reach/1`)
    * `:kind`     — `"content"` | `"job"` | `nil`
    * `:severity` — `"info"` | `"warn"` | `"error"` | `nil`
    * `:resources` — `:all` (the default) or the `"Elixir.Module"` strings whose entries are shown,
      as `MishkaCmsCore.Activity.Helpers.resources_for/1` answers for a viewer
    * `:limit`    — page size (Ash sets this to `page_size + 1` so `more?` works)
    * `:offset`   — page offset
  """
  def page(opts) do
    site_id = Map.get(opts, :site_id)
    kind = Map.get(opts, :kind)
    severity = Map.get(opts, :severity)
    shown = shown(opts)
    resource = blank(Map.get(opts, :resource))
    search = like(Map.get(opts, :search))
    limit = Map.get(opts, :limit, @default_limit)
    offset = Map.get(opts, :offset, 0)
    cap = min(offset + limit, @max_cap)

    site_id
    |> branches(kind, severity, shown)
    |> run(site_id, cap, limit, offset, resource, search)
  end

  @doc "The most rows any one branch is scanned for — a count that reaches it means \"or more\"."
  @spec max_cap() :: pos_integer()
  def max_cap, do: @max_cap

  @doc """
  How many entries `page/1` has to show, as `%{total: n, info: n, warn: n, error: n}` — the log's KPI
  row and its "showing 1–20 of N" label.

  Takes the same opts as `page/1` minus `:severity`, `:limit` and `:offset`: each figure is a COUNT
  over the very same UNION, so a count always agrees with the list beside it. Like `page/1`, every
  branch is capped at `@max_cap`, so a log past that reports the cap rather than scanning forever.
  """
  @spec counts(map()) :: %{
          total: non_neg_integer(),
          info: non_neg_integer(),
          warn: non_neg_integer(),
          error: non_neg_integer()
        }
  def counts(opts \\ %{}) do
    site_id = Map.get(opts, :site_id)
    kind = Map.get(opts, :kind)
    resource = blank(Map.get(opts, :resource))
    search = like(Map.get(opts, :search))
    shown = shown(opts)

    %{total: nil, info: "info", warn: "warn", error: "error"}
    |> Map.new(fn {key, severity} ->
      {key,
       site_id
       |> branches(kind, severity, shown)
       |> count(site_id, resource, search)}
    end)
  end

  @doc """
  How many entries match `opts` in total — what `page/1` is showing a window of.

  Same opts as `page/1` minus `:limit`/`:offset`. The read hands this to Ash as `full_count` so the
  table can say how far into the log a page reaches; `Ash.DataLayer.Simple` cannot count a manual
  read by itself. Capped like `page/1`, so a log past `@max_cap` reports the cap.
  """
  @spec total(map()) :: non_neg_integer()
  def total(opts \\ %{}) do
    site_id = Map.get(opts, :site_id)

    site_id
    |> branches(Map.get(opts, :kind), Map.get(opts, :severity), shown(opts))
    |> count(site_id, blank(Map.get(opts, :resource)), like(Map.get(opts, :search)))
  end

  @doc """
  How many entries fall on each day, as `%{~D[2026-07-16] => 15}` — the "15 events" beside a day's
  heading in the timeline.

  Takes the same opts as `counts/1`. One GROUP BY over the same UNION, so the figure is the day's REAL
  total rather than however much of that day happens to be loaded — the log pages with `load_more`, and
  a heading that counted only the loaded rows would keep changing as you scroll.
  """
  @spec day_counts(map()) :: %{Date.t() => non_neg_integer()}
  def day_counts(opts \\ %{}) do
    site_id = Map.get(opts, :site_id)
    kind = Map.get(opts, :kind)
    resource = blank(Map.get(opts, :resource))
    search = like(Map.get(opts, :search))

    case branches(site_id, kind, Map.get(opts, :severity), shown(opts)) do
      [] ->
        %{}

      branches ->
        sql = """
        SELECT day, COUNT(*) FROM (
          SELECT inserted_at::date AS day FROM (
          #{Enum.join(branches, "\n  UNION ALL\n")}
          ) t
          LIMIT $2 OFFSET $3
        ) capped
        GROUP BY day
        """

        params = [@max_cap, @max_cap, 0, resource, search] ++ if(site_id, do: [site_id], else: [])

        case Ecto.Adapters.SQL.query(@repo, sql, params) do
          {:ok, %{rows: rows}} -> Map.new(rows, fn [day, total] -> {day, total} end)
          other -> log_failure("sparkline", other, %{})
        end
    end
  end

  defp count([], _site_id, _resource, _search), do: 0

  # Same param shape as `run/6` — the branches read $1/$4/$5/$6, and the LIMIT/OFFSET keeps $2/$3
  # referenced so Postgres can still infer their types (they are positional, so neither can be
  # skipped). The limit doubles as the cap: a log past `@max_cap` reports the cap.
  defp count(branches, site_id, resource, search) do
    sql = """
    SELECT COUNT(*) FROM (
      SELECT 1 FROM (
      #{Enum.join(branches, "\n  UNION ALL\n")}
      ) t
      LIMIT $2 OFFSET $3
    ) capped
    """

    params = [@max_cap, @max_cap, 0, resource, search] ++ if(site_id, do: [site_id], else: [])

    case Ecto.Adapters.SQL.query(@repo, sql, params) do
      {:ok, %{rows: [[total]]}} -> total
      other -> log_failure("count", other, 0)
    end
  end

  @doc """
  Bulk-resolve actor `user_id`s to `%{email, site_id}` in ONE query — so the table's
  actor column doesn't `Ash.get` per row (an N+1 that also dragged in the user's
  permissions/site loads). `id = ANY($1::text[]::uuid[])` keeps the param text
  (Postgrex-friendly) while comparing against the un-cast uuid pkey.

  Scoped to the `viewer`: a site user loads only its own site's users, so another
  site's or a master's email never reaches the request. A master (a user whose
  `site_id` is nil) loads any actor. No viewer, or anything that is not a user,
  loads nothing. `MishkaCmsCore.Activity.Helpers.actor_labels/2` names the rest.
  """
  def actor_emails(user_ids, viewer \\ nil)
  def actor_emails([], _viewer), do: %{}

  def actor_emails(user_ids, %{site_id: site_id}) when is_binary(site_id) do
    sql =
      "SELECT id::text, email::text, site_id::text FROM users " <>
        "WHERE id = ANY($1::text[]::uuid[]) AND site_id = $2::text::uuid"

    decode_emails(sql, [user_ids, site_id])
  end

  def actor_emails(user_ids, %{site_id: nil}) do
    sql =
      "SELECT id::text, email::text, site_id::text FROM users WHERE id = ANY($1::text[]::uuid[])"

    decode_emails(sql, [user_ids])
  end

  def actor_emails(_user_ids, _nobody), do: %{}

  defp decode_emails(sql, params) do
    case Ecto.Adapters.SQL.query(@repo, sql, params) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [id, email, site_id] -> {id, %{email: email, site_id: site_id}} end)

      other ->
        log_failure("actors", other, %{})
    end
  end

  @doc "Bulk-resolve site `id`s to their name in ONE query (archived included)."
  def site_names([]), do: %{}

  def site_names(site_ids) do
    sql = "SELECT id::text, name FROM sites WHERE id = ANY($1::text[]::uuid[])"

    case Ecto.Adapters.SQL.query(@repo, sql, [site_ids]) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [id, name] -> {id, name} end)
      other -> log_failure("sites", other, %{})
    end
  end

  defp branches(site_id, kind, severity, shown) do
    []
    |> maybe_concat(kind in [nil, "content"], fn -> version_branches(site_id, severity, shown) end)
    |> maybe_concat(kind in [nil, "content"], fn -> event_branches(site_id, severity, shown) end)
    |> maybe_concat(kind in [nil, "content"], fn -> draft_branches(site_id, severity, shown) end)
    |> maybe_concat(kind in [nil, "content"], fn -> editor_branches(site_id, severity, shown) end)
    |> maybe_concat(kind in [nil, "job"], fn -> oban_branches(site_id, severity, shown) end)
  end

  # WHOSE ENTRIES A VIEWER'S LOG SHOWS: `:all`, or only those of the resources named. A name is a
  # module string, checked by `valid_module?/1` before it is written into the SQL.
  defp shown(opts) do
    case Map.get(opts, :resources, :all) do
      :all -> :all
      resources when is_list(resources) -> Enum.filter(resources, &valid_module?/1)
    end
  end

  defp shown_clause(_expr, :all), do: ""
  defp shown_clause(_expr, []), do: " AND FALSE"

  defp shown_clause(expr, resources),
    do: " AND #{expr} IN (#{Enum.map_join(resources, ", ", &"'#{&1}'")})"

  defp maybe_concat(acc, true, fun), do: acc ++ fun.()
  defp maybe_concat(acc, false, _fun), do: acc

  defp version_branches(_site_id, "error", _shown), do: []

  defp version_branches(site_id, severity, shown) do
    for resource <- Discovery.paper_trailed(),
        version = version_resource(resource),
        table = table_for(version),
        valid_ident?(table),
        module = to_string(resource),
        valid_module?(module),
        Helpers.shows?(shown, module) do
      user_col =
        if Ash.Resource.Info.attribute(version, :user_id), do: "user_id::text", else: "NULL::text"

      """
      (SELECT 'version' AS source, '#{module}' AS resource,
              version_action_name::text AS action,
              version_source_id::text AS source_id,
              NULL::text AS event_id,
              site_id::text AS site_id,
              #{user_col} AS user_id,
              version_inserted_at AS inserted_at,
              (COALESCE(changes, '{}'::jsonb) || COALESCE(version_action_inputs, '{}'::jsonb)) AS payload
         FROM #{table}
        WHERE TRUE#{version_site_clause(site_id, shares_globals?(resource))}#{content_severity_clause(severity, "version_action_name")}#{resource_clause("'#{module}'")}#{search_clause(["'#{module}'", "version_action_inputs::text", "COALESCE(changes->>'title', changes->>'name')"])}
        ORDER BY version_inserted_at DESC
        LIMIT $1)\
      """
    end
  end

  defp event_branches(_site_id, "error", _shown), do: []

  defp event_branches(site_id, severity, shown) do
    site_expr = "COALESCE(metadata->>'site_id', data->>'site_id')"

    for resource <- Discovery.event_logs(),
        table = table_for(resource),
        valid_ident?(table) do
      """
      (SELECT 'event' AS source, resource::text AS resource,
              action::text AS action,
              record_id::text AS source_id,
              id::text AS event_id,
              #{site_expr} AS site_id,
              actor_id::text AS user_id,
              occurred_at AS inserted_at,
              (COALESCE(metadata, '{}'::jsonb) || COALESCE(data, '{}'::jsonb)) AS payload
         FROM #{table}
        WHERE TRUE#{site_text_clause(site_id, site_expr)}#{content_severity_clause(severity, "action")}#{resource_clause("resource::text")}#{shown_clause("resource::text", shown)}#{search_clause(["resource::text", "data::text", "COALESCE(metadata->>'title', metadata->>'name')"])}
        ORDER BY occurred_at DESC
        LIMIT $1)\
      """
    end
  end

  # Runtime drafts (Page/Layout/ErrorPage) have no version/event/oban trail, so query each draft
  # table directly — one branch per table. One row = one draft's latest state, which is either
  # published (`status='published'`) or not.
  #
  # A discard is NOT reportable from here. These three resources do not archive — `destroy :destroy`
  # is a plain destroy — so discarding a draft removes the row and there is nothing left to select.
  # Only the live PubSub feed sees it, at the moment it happens
  # (`MishkaCmsCore.Activity.Sources.RuntimeDraft.handle_broadcast/1`).
  #
  # An earlier version DID soft-delete, and this branch read `archived_at` to spot it. When the
  # column went, every one of these branches started failing — and because `run/6` answers a failed
  # query with an empty list, that emptied the WHOLE log, silently, every branch, not just drafts.
  # Skipped for both severities a draft can no longer reach. `@warn_actions` is the destroy family,
  # and with the destroy arm gone this branch emits only 'publish' or 'update' — so a `warn` read
  # would scan all three draft tables to return nothing, every time. Same shape as
  # `version_branches/2`'s `"error"` skip.
  defp draft_branches(_site_id, severity, _shown) when severity in ["warn", "error"], do: []

  defp draft_branches(site_id, severity, shown) do
    action_expr = "(CASE WHEN status = 'published' THEN 'publish' ELSE 'update' END)"

    @draft_tables
    |> Enum.filter(&Helpers.shows?(shown, &1.module))
    |> Enum.map(fn cfg ->
      """
      (SELECT 'draft' AS source, '#{cfg.module}' AS resource,
              #{action_expr} AS action,
              id::text AS source_id,
              NULL::text AS event_id,
              site_id::text AS site_id,
              NULL::text AS user_id,
              updated_at AS inserted_at,
              jsonb_build_object('name', name, 'path', path) AS payload
         FROM #{cfg.table}
        WHERE TRUE#{version_site_clause(site_id, cfg.shared?)}#{content_severity_clause(severity, action_expr)}#{resource_clause("'#{cfg.module}'")}#{search_clause(["name", "path"])}
        ORDER BY updated_at DESC
        LIMIT $1)\
      """
    end)
  end

  # THE EDITOR'S OWN RECORD. Nothing else can see it: `PageBuilderEvent` is not versioned, not an
  # events log and not a job, so without this branch a whole afternoon in the page builder leaves the
  # global feed empty while the editor's own sheet is full.
  #
  # Skipped for the two severities it cannot reach — every row is somebody making a change, which is
  # information rather than a warning — so a `warn` read does not scan the table to return nothing.
  defp editor_branches(_site_id, severity, _shown) when severity in ["warn", "error"], do: []

  defp editor_branches(site_id, severity, shown) do
    # SAID IN THE FEED'S OWN WORDS. The editor files a change under content, style or publish, and
    # the feed has one shared vocabulary every source reports in — widening it for one source would
    # change how the others render. A publish is a publish; everything else is an update to the
    # document, and the message beside it says which ("Set gap (base) — <nav>").
    action_expr = "(CASE WHEN kind::text = 'publish' THEN 'publish' ELSE 'update' END)"

    # THE MODULE NAME, NOT THE SECTION. Every other branch reports a resource as
    # `Elixir.MishkaCmsCore.Runtime.Page`, and that is what a resource-scoped feed filters on — a
    # branch answering `page` would be shown in every document's System Log and filtered out of its
    # own. Built here rather than in Elixir because the filter is applied in SQL.
    resource_expr = """
    (CASE source_type::text
       WHEN 'page' THEN 'Elixir.MishkaCmsCore.Runtime.Page'
       WHEN 'layout' THEN 'Elixir.MishkaCmsCore.Runtime.Layout'
       WHEN 'component' THEN 'Elixir.MishkaCmsCore.Runtime.Component'
       WHEN 'error_page' THEN 'Elixir.MishkaCmsCore.Runtime.ErrorPage'
     END)\
    """

    [
      """
      (SELECT 'editor' AS source, #{resource_expr} AS resource,
              #{action_expr} AS action,
              source_id::text AS source_id,
              id::text AS event_id,
              site_id::text AS site_id,
              author_id::text AS user_id,
              inserted_at AS inserted_at,
              jsonb_build_object('label', label, 'target', target) AS payload
         FROM page_builder_events
        WHERE TRUE#{version_site_clause(site_id, false)}#{content_severity_clause(severity, action_expr)}#{resource_clause(resource_expr)}#{shown_clause(resource_expr, shown)}#{search_clause(["label", "target"])}
        ORDER BY inserted_at DESC
        LIMIT $1)\
      """
    ]
  end

  defp oban_branches(site_id, severity, shown) do
    site_expr = "COALESCE(args->>'site_id', args#>>'{data,site_id}')"

    # WHO CAUSED THE JOB. `SendToOban` stamps the acting user onto the args — the same actor the
    # PaperTrail version of that very save records — so a failed compile names the person whose edit
    # caused it instead of answering "System". A job nobody triggered (a cron, a boot) has no
    # `actor_id` and correctly stays System.
    actor_expr = "args->>'actor_id'"

    [
      """
      (SELECT 'job' AS source, worker::text AS resource,
              state::text AS action,
              id::text AS source_id,
              id::text AS event_id,
              #{site_expr} AS site_id,
              #{actor_expr} AS user_id,
              COALESCE(completed_at, discarded_at, inserted_at) AS inserted_at,
              args AS payload
         FROM #{@oban_table}
        WHERE state::text IN (#{oban_states(severity)})#{site_text_clause(site_id, site_expr)}#{resource_clause("('Elixir.' || (args->>'resource'))")}#{shown_clause("('Elixir.' || (args->>'resource'))", shown)}#{search_clause(["worker::text", "args::text"])}
        ORDER BY COALESCE(completed_at, discarded_at, inserted_at) DESC
        LIMIT $1)\
      """
    ]
  end

  defp run([], _site_id, _cap, _limit, _offset, _resource, _search), do: []

  # Params: $1 = cap, $2 = limit, $3 = offset, $4 = resource (or nil), $5 = search
  # (or nil), $6 = tenant site_id (tenant only).
  defp run(branches, site_id, cap, limit, offset, resource, search) do
    sql = """
    SELECT source, resource, action, source_id, event_id, site_id, user_id, inserted_at, payload
    FROM (
    #{Enum.join(branches, "\n  UNION ALL\n")}
    ) t
    ORDER BY inserted_at DESC NULLS LAST
    LIMIT $2 OFFSET $3
    """

    params = [cap, limit, offset, resource, search] ++ if(site_id, do: [site_id], else: [])

    case Ecto.Adapters.SQL.query(@repo, sql, params) do
      {:ok, %{columns: columns, rows: rows}} -> decode(columns, rows)
      other -> log_failure("page", other, [])
    end
  end

  # An empty answer and a BROKEN answer look identical to every caller here, and the log page draws
  # both as "No matching events". That is how a dropped column went unnoticed: one branch referenced
  # `archived_at` after it was removed, the UNION failed, and the whole log read zero — every source,
  # silently, with nothing anywhere to say why.
  #
  # The empty return stays: a log page that renders is better than one that 500s, and these queries
  # are read-only. What changes is that the failure is now on the record.
  defp log_failure(what, reason, empty) do
    Logger.error("[Activity.Query] #{what} query failed, answering empty: #{inspect(reason)}")
    empty
  end

  defp decode(columns, rows) do
    index = columns |> Enum.with_index() |> Map.new()

    # `complete_entry/1` is the seam: a source writes whatever map it likes, and what leaves here is
    # always whole, so the widgets and the timeline can dot-access an entry without a KeyError.
    Enum.map(rows, fn row -> row |> to_map(index) |> dispatch() |> Helpers.complete_entry() end)
  end

  defp to_map(row, index), do: Map.new(index, fn {column, i} -> {column, Enum.at(row, i)} end)

  defp dispatch(%{"source" => "version"} = row), do: PaperTrail.entry_from_row(row)
  defp dispatch(%{"source" => "event"} = row), do: EventLog.entry_from_row(row)
  defp dispatch(%{"source" => "draft"} = row), do: RuntimeDraft.entry_from_row(row)
  defp dispatch(%{"source" => "job"} = row), do: Oban.entry_from_row(row)
  defp dispatch(%{"source" => "editor"} = row), do: EditorHistory.entry_from_row(row)

  # Tenant version scope. A tenant always sees its OWN site; it ALSO sees global
  # (site_id IS NULL) rows ONLY for resources that share their globals with tenants
  # (`shares_globals?/1`) — i.e. the runtime resources whose own admin page already
  # shows globals read-only (Component/Layout/JsHook/Stylesheet). It never sees
  # another tenant. Master (site_id nil) gets no clause and sees everything.
  #
  # `$4::text::uuid` (not `$4::uuid`): the inner `::text` forces Postgrex to send
  # $4 as text — the same type the event/oban jsonb branches compare against — so
  # one text param serves every branch; the outer `::uuid` makes the right side a
  # uuid constant, leaving the column un-cast so the index is usable.
  defp version_site_clause(nil, _shared?), do: ""

  defp version_site_clause(_site_id, true),
    do: " AND (site_id = $6::text::uuid OR site_id IS NULL)"

  defp version_site_clause(_site_id, false), do: " AND site_id = $6::text::uuid"

  # Events (per-extension logs) and Oban jobs are NOT globally shared with tenants,
  # so a tenant sees only its own site for those — never global.
  defp site_text_clause(nil, _expr), do: ""
  defp site_text_clause(_site_id, expr), do: " AND #{expr} = $6::text"

  defp resource_clause(expr), do: " AND ($4::text IS NULL OR #{expr} = $4::text)"

  defp search_clause(exprs) do
    ors = Enum.map_join(exprs, " OR ", &"#{&1} ILIKE $5::text")
    " AND ($5::text IS NULL OR #{ors})"
  end

  defp blank(value) when value in [nil, "", "all"], do: nil
  defp blank(value), do: to_string(value)

  defp like(value) when value in [nil, ""], do: nil

  defp like(value) when is_binary(value),
    do: "%" <> String.replace(value, ~r/[\\%_]/, fn ch -> "\\" <> ch end) <> "%"

  defp like(_), do: nil

  @doc """
  Grouped options for the resource/source `:select` filter — one `{extension_label,
  [{resource_label, module_string}]}` group per extension (so same-named resources
  in different extensions, e.g. Blog vs Document "Tag", stay distinct).
  Covers version parent modules + distinct event-log `resource` values; the value
  is the module string the SQL filters on.
  """
  def resource_options do
    versions = Enum.map(Discovery.paper_trailed(), &to_string/1)

    events =
      Discovery.event_logs()
      |> Enum.map(&table_for/1)
      |> Enum.filter(&valid_ident?/1)
      |> Enum.flat_map(&distinct_event_resources/1)

    (versions ++ events ++ Enum.map(@draft_tables, & &1.module))
    |> Enum.uniq()
    |> Enum.group_by(&group_label_of/1, &{resource_label_of(&1), &1})
    |> Enum.map(fn {group, opts} -> {group, Enum.sort_by(opts, &elem(&1, 0))} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp group_label_of(resource_string) do
    resource_string
    |> String.split(".")
    |> Enum.at(1, gettext("Other"))
    |> String.replace(~r/([A-Z])/, " \\1")
    |> String.trim()
  end

  @doc "Humanise a `\"Elixir.A.B.Thing\"` resource string to `\"Thing\"` (spaced)."
  def resource_label_of(resource_string) do
    resource_string
    |> String.split(".")
    |> List.last()
    |> String.replace(~r/([A-Z])/, " \\1")
    |> String.trim()
    |> Helpers.translate()
  end

  defp distinct_event_resources(table) do
    sql = "SELECT DISTINCT resource FROM #{table} WHERE resource IS NOT NULL"

    case Ecto.Adapters.SQL.query(@repo, sql, []) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [r] -> r end)
      other -> log_failure("resources", other, [])
    end
  end

  @doc """
  Whether a resource shares its global (`site_id` nil) rows with tenants — true iff
  it exposes the `:for_tenant_with_globals` read, the same rule its own admin page
  uses (Component, Layout, JsHook, Stylesheet). Tenants see global activity only for
  these; everything else (Page, ErrorPage, Media, blog, document, …) stays
  own-site-only for tenants.
  """
  def shares_globals?(resource),
    do: !is_nil(Ash.Resource.Info.action(resource, :for_tenant_with_globals))

  defp content_severity_clause("warn", column), do: " AND #{column} IN (#{@warn_actions})"
  defp content_severity_clause("info", column), do: " AND #{column} NOT IN (#{@warn_actions})"
  # Catch-all (incl. nil) → no severity predicate. Total by construction, so a value
  # that slips past the normalize_filters whitelist can never raise here.
  defp content_severity_clause(_severity, _column), do: ""

  defp oban_states("info"), do: "'completed'"
  defp oban_states("warn"), do: "'retryable'"
  defp oban_states("error"), do: "'discarded'"
  # Catch-all (incl. nil) → all job states.
  defp oban_states(_severity), do: "'completed','discarded','retryable'"

  defp version_resource(resource), do: AshPaperTrail.Resource.Info.version_resource(resource)

  defp table_for(nil), do: nil
  defp table_for(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp valid_ident?(table) when is_binary(table), do: Regex.match?(~r/^[a-zA-Z0-9_]+$/, table)
  defp valid_ident?(_), do: false

  defp valid_module?(module), do: Regex.match?(~r/^[a-zA-Z0-9_.]+$/, module)
end
