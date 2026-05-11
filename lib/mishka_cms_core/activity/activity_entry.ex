defmodule MishkaCmsCore.Activity.ActivityEntry do
  @moduledoc """
  Synthetic, read-only resource representing one unified activity-log entry, and
  the gervaz timeline table over it.

  No database table — `Ash.DataLayer.Simple` plus a single `manual` read whose
  `manual_read/2` delegates to `MishkaCmsCore.Activity.Query`, which merges every
  AshPaperTrail version table + AshEvents event log + Oban jobs in ONE DB-side
  UNION. Attributes mirror the `MishkaCmsCore.Activity.Behaviours.Source` entry
  shape so gervaz columns/filters bind by name and the stream gets a stable `:id`.

  Tenant scoping is enforced in the query (Ash won't enforce multitenancy for a
  manual-over-Simple read): a master sees every site; a tenant sees its own site
  plus global rows of the shared runtime resources (`Query.shares_globals?/1`),
  never another tenant. The `:activity_site` column is shown to everyone (a tenant's
  rows resolve to its own site or "Global").
  """
  use Ash.Resource,
    domain: MishkaCmsCore.Activity.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [MishkaGervaz.Resource],
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext
  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Activity.{Helpers, Query}

  @entry_keys [
    :id,
    :resource_label,
    :action,
    :severity,
    :tone,
    :inserted_at,
    :source_id,
    :site_id,
    :user_id,
    :message,
    :badge_label,
    :badge_tone,
    :actor_label,
    :site_label
  ]

  @default_limit 20

  mishka_gervaz do
    table do
      identity do
        name :activity_logs
        route "/admin/dashboard/runtime/activity"
        stream_name :activity_logs
      end

      source do
        actions do
          read :read
        end
      end

      columns do
        column :activity_info do
          static true
          requires [:action, :severity, :badge_tone, :resource_label, :message]
          label fn -> dgettext("mishka_gervaz", "Activity") end
          position :first

          # The timeline node is the template's (it owns the rail); this is the message + its badge.
          render fn record ->
            assigns = %{message: record.message, resource_label: record.resource_label}

            ~H"""
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-[13px] font-semibold text-[#1b1a18]">{@message}</span>
              <span class="rounded-md bg-[#eeedfb] px-[7px] py-0.5 text-[8.5px] font-bold tracking-[0.05em] text-[#5b57d6]">
                {@resource_label}
              </span>
            </div>
            """
          end
        end

        column :activity_actor do
          static true
          requires [:user_id, :id, :actor_label, :severity, :tone]
          label fn -> dgettext("mishka_gervaz", "Actor") end

          # The avatar echoes the row's tone-or-severity, like the timeline node beside it — not the
          # actor, which the name already says.
          render fn record, state ->
            name = record.actor_label || actor_name(record.user_id, state.current_user)

            assigns = %{
              id: record.id,
              initials: Helpers.initials(name),
              name: name,
              tone: record.tone || record.severity
            }

            ~H"""
            <span id={"activity-actor-#{@id}"} class="inline-flex items-center gap-[5px]">
              <span class={[
                "grid size-4 place-items-center rounded-[5px] font-['Space_Grotesk'] text-[8px] font-bold",
                @tone
              ]}>
                {@initials}
              </span>
              <span class="text-[11.5px] font-medium text-[#8a877f]">{@name}</span>
            </span>
            """
          end
        end

        column :activity_date do
          static true
          requires [:inserted_at]
          label fn -> dgettext("mishka_gervaz", "Date") end

          # The day heading above the row already carries the year; the row only needs the day.
          render fn record ->
            assigns = %{
              time: Calendar.strftime(record.inserted_at, "%H:%M"),
              day: Calendar.strftime(record.inserted_at, "%b %-d", Helpers.strftime_names())
            }

            ~H"""
            <div class="font-['Space_Grotesk'] text-[12px] font-semibold text-[#5c5a54]">
              {@time}
            </div>
            <div class="mt-0.5 text-[10.5px] font-medium text-[#bcb9b2]">{@day}</div>
            """
          end
        end

        column :activity_site do
          static true
          requires [:site_id, :site_label]
          label fn -> dgettext("mishka_gervaz", "Site") end

          render fn record ->
            assigns = %{site_name: record.site_label || site_name(record.site_id)}

            ~H"""
            <span class="inline-flex items-center gap-[5px] rounded-[20px] bg-[#f4f3ef] px-[9px] py-[3px] text-[10.5px] font-semibold text-[#6d6a63]">
              <.icon name="hero-globe-alt" class="size-[11px] text-[#a8a5a0]" />{@site_name}
            </span>
            """
          end
        end
      end

      filters do
        filter :severity, :select do
          source :severity

          options fn ->
            [
              {dgettext("mishka_gervaz", "Info"), "info"},
              {dgettext("mishka_gervaz", "Warning"), "warn"},
              {dgettext("mishka_gervaz", "Error"), "error"}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All severities")
            label fn -> dgettext("mishka_gervaz", "Severity") end
          end
        end

        filter :kind, :select do
          source :kind

          options fn ->
            [
              {dgettext("mishka_gervaz", "Content"), "content"},
              {dgettext("mishka_gervaz", "Background"), "job"}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All sources")
            label fn -> dgettext("mishka_gervaz", "Source") end
          end
        end

        filter :resource, :select do
          source :resource_label
          options fn -> MishkaCmsCore.Activity.Query.resource_options() end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All resources")
            label fn -> dgettext("mishka_gervaz", "Resource") end
          end
        end

        filter :search, :text do
          source :message

          ui do
            prompt dgettext_noop("mishka_gervaz", "Search events…")
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end
      end

      row do
        selectable false
      end

      pagination do
        type :load_more
        page_size 20

        ui do
          show_total true
          load_more_label dgettext_noop("mishka_gervaz", "Load more events")
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :page]
        prefix "activity"
        max_filter_length 500
      end

      presentation do
        template_options timestamp: :inserted_at, max_cap: Query.max_cap()
        features [:filter, :paginate]
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No matching events"),
                  icon: "hero-bars-3-bottom-left"

      hooks do
        # `full_count` is how a manual read tells Ash its total (`Ash.DataLayer.Simple` can't count
        # one itself) — with it set, the page carries a count and gervaz can say "20 of 10,000+ shown"
        # instead of guessing from the rows it happens to hold.
        on_load fn query, state ->
          filters = state.filter_values || %{}

          {:cont,
           query
           |> Ash.Query.set_argument(:gervaz_filters, filters)
           |> Ash.Query.set_context(%{
             full_count: MishkaCmsCore.Activity.ActivityEntry.total(state)
           })}
        end

        # The synthetic record has no DB row, so the default realtime path
        # (`reload_and_insert` → `Ash.get`) can't work. Insert the carried record
        # ourselves and halt — but only when it's visible to the viewer AND matches
        # the active filters (otherwise a new info job would jump into a
        # "Warning"-filtered view).
        on_realtime fn notification, socket ->
          state = socket.assigns.table_state
          record = notification.data

          socket =
            if MishkaCmsCore.Activity.ActivityEntry.live_visible?(record, state) do
              Phoenix.LiveView.stream_insert(socket, state.static.stream_name, record, at: 0)
            else
              socket
            end

          {:halt, socket}
        end
      end
    end
  end

  actions do
    default_accept []

    read :read do
      primary? true
      manual fn query, _data_layer_query, context -> manual_read(query, context) end

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      argument :gervaz_filters, :map, allow_nil?: true, default: %{}
    end
  end

  # The log is the admin's Activity page, so reading it takes the activity section,
  # `admin:<surface>:runtime:activity`. Whose rows it holds is decided in `manual_read/2` from the
  # viewer: the sites by
  # `MishkaCmsCore.Activity.Helpers.reach/1`, which gives every site to a master (`site_id` nil)
  # alone, and the resources by `MishkaCmsCore.Activity.Helpers.resources_for/1`, which gives a
  # holder the entries of the areas it holds.
  policies do
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:activity",
                      "admin:api:runtime:activity"
                    ]}
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :resource_label, :string, public?: true
    attribute :action, :atom, public?: true
    attribute :severity, :atom, public?: true

    # The content-change tone (`:created`/`:updated`/`:destroyed`) the timeline tints a create/update/
    # destroy row by; `nil` on every other source, which the timeline then colours by `:severity`.
    attribute :tone, :atom, public?: true
    attribute :kind, :atom, public?: true
    attribute :inserted_at, :utc_datetime_usec, public?: true
    attribute :source_id, :string, public?: true
    attribute :site_id, :string, public?: true
    attribute :user_id, :string, public?: true
    attribute :message, :string, public?: true
    attribute :badge_label, :string, public?: true
    attribute :badge_tone, :atom, public?: true
    # Resolved in bulk by the manual read (see resolve_labels/2) so the actor/site
    # columns never hit the DB per row.
    attribute :actor_label, :string, public?: true
    attribute :site_label, :string, public?: true
  end

  @doc """
  Builds an `%ActivityEntry{}` struct from a unified source entry map, deriving
  `:kind` (content vs background job). Used by the manual read and the live path.

  The day heading the timeline draws is the read's, not the entry's, so `mark_days/2`'s marks ride
  along as metadata (see `MishkaCmsCoreWeb.Templates.ActivityTimeline`); a live entry carries none
  and simply gets no heading.
  """
  def from_entry(entry) do
    __MODULE__
    |> struct(entry |> Map.take(@entry_keys) |> Map.put(:kind, kind_of(entry)))
    |> Ash.Resource.put_metadata(:first_of_day?, Map.get(entry, :first_of_day?, false))
    |> Ash.Resource.put_metadata(:day_count, Map.get(entry, :day_count, 0))
  end

  defp kind_of(%{id: "oban-" <> _}), do: :job
  defp kind_of(_), do: :content

  @doc """
  Whether a live record should appear in a given table view — tenant-visible AND
  matching the active filters. Used by the realtime `on_realtime` hook so a live
  insert never violates the current Severity/Source filter.
  """
  def live_visible?(record, state) do
    Helpers.visible_to?(record.site_id, state.current_user) and
      matches_view_filters?(record, state.filter_values)
  end

  defp matches_view_filters?(record, filter_values) do
    filters = normalize_filters(filter_values)

    severity_match?(record.severity, Map.get(filters, :severity)) and
      kind_match?(record.kind, Map.get(filters, :kind)) and
      resource_match?(record, Map.get(filters, :resource)) and
      search_match?(record, Map.get(filters, :search))
  end

  defp severity_match?(_severity, nil), do: true
  defp severity_match?(severity, value), do: to_string(severity) == value

  defp kind_match?(_kind, nil), do: true
  defp kind_match?(kind, value), do: to_string(kind) == value

  defp resource_match?(_record, nil), do: true
  defp resource_match?(record, value), do: record.resource_label == Query.resource_label_of(value)

  defp search_match?(_record, nil), do: true

  defp search_match?(record, term),
    do: String.contains?(String.downcase(record.message || ""), String.downcase(term))

  # The manual read backing the :read action. Delegates the merge to the DB:
  # `MishkaCmsCore.Activity.Query.page/1` runs one UNION across every source with
  # the tenant scope + gervaz filters (carried in via the `:gervaz_filters`
  # argument set by the `on_load` hook) pushed down, and lets Postgres do the
  # filtering, ordering and pagination. Ash sets limit = page_size + 1 and derives
  # `more?` from the extra row, so the load_more table needs no exact count.
  #
  # A read with no actor and `authorize?: false` is the system's own, and reads every site, as
  # system calls do everywhere; any other viewer reaches what `Helpers.reach/1` says.
  @doc false
  def manual_read(query, context) do
    actor = Map.get(context, :actor) || get_in(Map.get(context, :private, %{}), [:actor])

    case {actor, Map.get(context, :authorize?)} do
      {nil, false} -> read_page(query, nil, nil)
      _viewer -> read_as(query, actor)
    end
  end

  defp read_as(query, actor) do
    case Helpers.reach(actor) do
      :nothing -> {:ok, []}
      reach -> read_page(query, actor, scope_site_id(reach), Helpers.resources_for(actor))
    end
  end

  defp read_page(query, actor, site_id, resources \\ :all) do
    filters = normalize_filters(Ash.Query.get_argument(query, :gervaz_filters))
    limit = query.limit || @default_limit
    offset = query.offset || 0

    opts = %{
      site_id: site_id,
      kind: Map.get(filters, :kind),
      severity: Map.get(filters, :severity),
      resource: Map.get(filters, :resource),
      search: Map.get(filters, :search),
      resources: resources
    }

    # Read one row BEFORE the window too: it is what tells the first row of page 2 whether it really
    # opens a new day, or is just more of the day page 1 ended on. Without it every `load_more` would
    # repeat the heading mid-list. It is dropped again before the page is returned.
    lead = min(offset, 1)

    entries =
      opts
      |> Map.merge(%{limit: limit + lead, offset: offset - lead})
      |> Query.page()

    {:ok,
     entries
     |> resolve_labels(actor)
     |> mark_days(Query.day_counts(opts))
     |> Enum.drop(lead)
     |> Enum.map(&from_entry/1)}
  end

  # The log reads as one day-grouped stream, but the rows render through a LiveView stream — which
  # never hands a row its predecessor. The page IS ordered here, so each entry is told whether it
  # opens a new day, and the opener carries that day's total; the template draws the heading off both.
  defp mark_days(entries, day_counts) do
    entries
    |> Enum.map_reduce(nil, fn entry, previous_day ->
      day = entry.inserted_at && DateTime.to_date(entry.inserted_at)
      opens? = day != previous_day

      entry =
        entry
        |> Map.put(:first_of_day?, opens?)
        |> Map.put(:day_count, (opens? && Map.get(day_counts, day, 0)) || 0)

      {entry, day}
    end)
    |> elem(0)
  end

  @doc """
  How many entries the table's current view matches — the total behind "20 of 10,000+ shown", scoped
  to the viewer and narrowed by whatever filters are active. Called from the `on_load` hook, which is
  where gervaz's filter state lives.
  """
  @spec total(map()) :: non_neg_integer()
  def total(state) do
    case Helpers.reach(state.current_user) do
      :nothing -> 0
      reach -> count(state, scope_site_id(reach), Helpers.resources_for(state.current_user))
    end
  end

  defp count(state, site_id, resources) do
    filters = normalize_filters(state.filter_values || %{})

    Query.total(%{
      site_id: site_id,
      kind: Map.get(filters, :kind),
      severity: Map.get(filters, :severity),
      resource: Map.get(filters, :resource),
      search: Map.get(filters, :search),
      resources: resources
    })
  end

  @doc """
  The log's KPI totals for `viewer` — `%{total:, info:, warn:, error:}` over the sites and the areas
  it may see (`MishkaCmsCore.Activity.Query.counts/1`). All zero for no viewer.
  """
  @spec counts(map() | nil) :: %{
          total: non_neg_integer(),
          info: non_neg_integer(),
          warn: non_neg_integer(),
          error: non_neg_integer()
        }
  def counts(viewer) do
    case Helpers.reach(viewer) do
      :nothing ->
        %{total: 0, info: 0, warn: 0, error: 0}

      reach ->
        Query.counts(%{site_id: scope_site_id(reach), resources: Helpers.resources_for(viewer)})
    end
  end

  # `MishkaCmsCore.Activity.Query` reads a `nil` site as every site, which is a master's reach alone;
  # a viewer that reaches nothing never gets this far.
  defp scope_site_id(:everything), do: nil
  defp scope_site_id({:site, site_id}), do: site_id

  # Label every actor and site on the page in a fixed number of reads, as the viewer may see them.
  defp resolve_labels(entries, viewer) do
    actors = entries |> distinct_ids(:user_id) |> Helpers.actor_labels(viewer)
    sites = entries |> distinct_ids(:site_id) |> Query.site_names()

    Enum.map(entries, fn entry ->
      entry
      |> Map.put(:actor_label, Helpers.actor_label(actors, entry.user_id))
      |> Map.put(:site_label, site_label(entry.site_id, sites))
    end)
  end

  defp distinct_ids(entries, key),
    do: entries |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp normalize_filters(nil), do: %{}

  defp normalize_filters(map) when is_map(map),
    do: %{
      severity: allowed(filter_value(map, :severity), ~w(info warn error)),
      kind: allowed(filter_value(map, :kind), ~w(content job)),
      resource: filter_value(map, :resource),
      search: filter_value(map, :search)
    }

  defp filter_value(map, key),
    do: blank_to_nil(Map.get(map, key) || Map.get(map, to_string(key)))

  defp blank_to_nil(v) when v in [nil, "", "all"], do: nil
  defp blank_to_nil(v), do: to_string(v)

  # Coerce a URL-supplied filter value to its known enum (or nil). The gervaz
  # :select `options` are UI-only — UrlSync passes the raw value through — so this
  # is the boundary that stops an out-of-enum value (e.g. ?…severity=evil) from ever
  # reaching the SQL clause builders.
  defp allowed(value, set), do: if(value in set, do: value, else: nil)

  # One actor's label for a live insert, through the same resolver as a page.
  @doc false
  def actor_name(user_id, viewer),
    do: [user_id] |> Helpers.actor_labels(viewer) |> Helpers.actor_label(user_id)

  @doc false
  def site_name(nil), do: dgettext("mishka_gervaz", "Global")
  def site_name(site_id), do: site_label(site_id, Query.site_names([site_id]))

  defp site_label(nil, _sites), do: dgettext("mishka_gervaz", "Global")

  defp site_label(site_id, sites),
    do: Map.get(sites, site_id) || String.slice(site_id, 0, 8) <> "…"
end
