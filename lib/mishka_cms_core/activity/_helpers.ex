# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Helpers do
  @moduledoc """
  Shared helpers used by both the PaperTrail adapter's live-broadcast path
  and the version-resource calculations.

  Keeping these in one module makes the calc and the live path consistent:
  if you change how a destroy action maps to a severity, both code paths
  pick it up.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.Helper, as: AccountsHelper
  alias MishkaCmsCore.Activity.Discovery

  @tone_classes %{
    emerald: "bg-emerald-100 text-emerald-700",
    sky: "bg-sky-100 text-sky-700",
    amber: "bg-amber-100 text-amber-700",
    rose: "bg-rose-100 text-rose-700",
    indigo: "bg-indigo-100 text-indigo-700",
    violet: "bg-violet-100 text-violet-700",
    teal: "bg-teal-100 text-teal-700",
    fuchsia: "bg-fuchsia-100 text-fuchsia-700",
    slate: "bg-slate-100 text-slate-700"
  }

  @avatar_tones ~w(emerald sky amber rose indigo violet teal fuchsia)a

  @warn_actions [
    :destroy,
    :master_destroy,
    :permanent_destroy,
    :master_permanent_destroy
  ]

  # Every key an entry carries out of a source, and what a renderer draws when a source did not set
  # it. A source still writes its own map literal — this is the seam that guarantees whatever a
  # renderer receives is whole, so `entry.badge_tone` on a plain map cannot raise the way it did on
  # the dashboard's Recent activity card.
  #
  # `:inserted_at` defaults to nil and NOT to `utc_now()`: a fabricated timestamp sorts a broken row
  # to the top of every feed and invents a day heading for it, which is worse than a row that does
  # not draw. The presentational keys default to nil because every tone/badge/dot helper that reads
  # one already ends in a catch-all clause.
  @entry_defaults %{
    id: nil,
    resource_label: nil,
    action: :other,
    severity: :info,
    tone: nil,
    badge_label: nil,
    badge_tone: nil,
    inserted_at: nil,
    source_id: nil,
    site_id: nil,
    user_id: nil,
    message: nil
  }

  @doc """
  The keys every activity entry carries — the same list `MishkaCmsCore.Activity.Behaviours.Source`
  states as a type, as data, so a test can hold a source to it.
  """
  @spec entry_keys() :: [atom()]
  def entry_keys, do: Map.keys(@entry_defaults)

  @doc """
  Fill in whatever key a source left out of an entry.

  Sources are pluggable and each writes its own map literal, so one that forgets a key hands a
  renderer a map that `entry.that_key` raises on — which in a LiveView is a dead process, and on the
  dashboard a reconnect loop. Both places an entry enters the system pass it through here first (the
  DB merge in `MishkaCmsCore.Activity.Query.decode/2`, the live feed in
  `MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed`), so dot-access downstream of either seam is
  safe. A key the entry already carries is never overwritten, and extra keys ride along untouched.

  `nil` passes through: the live path uses it to mean "no source claimed this broadcast".
  """
  @spec complete_entry(map() | nil) :: map() | nil
  def complete_entry(nil), do: nil
  def complete_entry(entry) when is_map(entry), do: Map.merge(@entry_defaults, entry)

  @doc """
  The actions the activity feed reads as `:warn` — a destroy of any kind. The one list behind both
  `severity_for/1` and any consumer that has to ask for them in a query (e.g. the event log's KPI
  counts).
  """
  @spec warn_actions() :: [atom()]
  def warn_actions, do: @warn_actions

  @doc """
  Map a PaperTrail action atom (e.g. `:create`, `:master_destroy`) to a
  severity level used by the activity feed UI.
  """
  def severity_for(action) when action in @warn_actions, do: :warn

  def severity_for(_), do: :info

  @doc """
  Map a content-change action atom to the TONE the activity timeline tints its row by — the colour
  that says WHAT happened, kept apart from `severity_for/1` (the KPI cards count by severity, so it
  must not carry action meaning). A create reads `:created` (green), an update `:updated` (blue) and
  any destroy — the same `warn_actions/0` — `:destroyed` (red). Anything that is not one of those
  three (a publish, an unarchive, a job outcome, a compile) is `nil`, so the timeline falls back to
  colouring that row by its `severity`.
  """
  @spec tone_for(atom()) :: :created | :updated | :destroyed | nil
  def tone_for(action) when action in [:create, :master_create], do: :created
  def tone_for(action) when action in [:update, :master_update], do: :updated
  def tone_for(action) when action in @warn_actions, do: :destroyed
  def tone_for(_action), do: nil

  @known_actions ~w(create master_create update master_update publish master_publish
                    destroy master_destroy permanent_destroy master_permanent_destroy
                    unarchive master_unarchive restore_version completed discarded
                    exception retryable)a

  @doc """
  Normalise an action coming back from a raw SQL row (a string) to the canonical
  atom, or `:other` for an unknown cross-extension action. Never creates a new
  atom (no leak, no raise) — a foreign action name simply maps to `:other`.
  """
  def action_atom(action) when is_atom(action), do: action

  def action_atom(action) when is_binary(action),
    do: Enum.find(@known_actions, :other, fn known -> Atom.to_string(known) == action end)

  def action_atom(_), do: :other

  @doc """
  Coerce a timestamp from a raw SQL row into a UTC `DateTime`. Postgres
  `timestamp without time zone` columns come back as `NaiveDateTime`.
  """
  def to_datetime(%DateTime{} = at), do: at
  def to_datetime(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  def to_datetime(_), do: DateTime.utc_now()

  @doc """
  Human-readable label for a resource module. Splits the module name on
  capitals (`MediaCategory` → `Media Category`). Used by the live path
  where the version row's `:resource_label` calculation isn't loaded.
  """
  def humanize_module(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.replace(~r/([A-Z])/, " \\1")
    |> String.trim()
    |> translate()
  end

  @doc """
  The words `label` stands for in the process's locale, in the default Gettext domain; `label`
  itself when no translation has it.
  """
  @spec translate(String.t()) :: String.t()
  def translate(label) when is_binary(label), do: Gettext.gettext(MishkaCmsCore.Gettext, label)

  @doc """
  Map a PaperTrail action atom to a `{badge_label, tone}` tuple used by
  the activity feed UI. Tone is one of the Tailwind palette keys the
  template knows how to render (`:emerald`, `:sky`, `:amber`, `:rose`,
  `:indigo`, `:slate`).
  """
  def paper_trail_badge(action) when action in [:create, :master_create],
    do: {gettext("CREATE"), :emerald}

  def paper_trail_badge(action) when action in [:update, :master_update],
    do: {gettext("UPDATE"), :sky}

  def paper_trail_badge(action) when action in [:destroy, :master_destroy],
    do: {gettext("ARCHIVE"), :amber}

  def paper_trail_badge(action) when action in [:permanent_destroy, :master_permanent_destroy],
    do: {gettext("PURGE"), :rose}

  def paper_trail_badge(action) when action in [:unarchive, :master_unarchive],
    do: {gettext("RESTORE"), :emerald}

  def paper_trail_badge(:restore_version), do: {gettext("REVERT"), :indigo}

  def paper_trail_badge(:publish), do: {gettext("PUBLISH"), :slate}

  def paper_trail_badge(action) when is_atom(action),
    do: {action |> to_string() |> String.upcase() |> translate(), :slate}

  @doc """
  Whose activity `viewer` may see: `:everything` for a master (a user whose `site_id` is nil),
  `{:site, site_id}` for a site user, and `:nothing` for no viewer or anything that is not a user.

  Every source, the activity log's read and the live feed ask this, so a missing viewer is never
  read as a master.
  """
  @spec reach(map() | nil) :: :everything | {:site, String.t()} | :nothing
  def reach(%{site_id: nil}), do: :everything
  def reach(%{site_id: site_id}) when is_binary(site_id), do: {:site, site_id}
  def reach(_nobody), do: :nothing

  @doc """
  Whose entries `viewer`'s Activity log shows, by area: `:all` for a full dashboard admin
  (`admin:dashboard:*`), otherwise the resources — as `"Elixir.Module"` strings, the way the log
  names them — whose areas (`MishkaCmsCore.Activity.Discovery.areas/1`) the viewer holds on the
  dashboard. A resource that names no area is a full admin's alone.
  """
  @spec resources_for(map() | nil) :: :all | [String.t()]
  def resources_for(viewer) do
    case AccountsHelper.full_admin?(viewer, :dashboard) do
      true -> :all
      false -> held_resources(AccessPermissions.with_permissions(viewer))
    end
  end

  defp held_resources(viewer) do
    for resource <- Discovery.resources(),
        names = Discovery.areas(resource),
        names != [],
        AccessPermissions.match?(viewer, %{}, permissions: names),
        uniq: true,
        do: to_string(resource)
  end

  @doc """
  Whether a log showing `resources` (`resources_for/1`) shows `resource`, a module or its
  `"Elixir.Module"` string. `:all` shows everything; otherwise an entry with no resource is shown to
  nobody.
  """
  @spec shows?(:all | [String.t()], module() | String.t() | nil) :: boolean()
  def shows?(:all, _resource), do: true
  def shows?(_resources, nil), do: false
  def shows?(resources, resource), do: to_string(resource) in resources

  @doc """
  Whether a live entry is visible to `viewer` on the realtime feed. A master (`site_id`
  nil) sees every site; a tenant sees only its OWN site (never another tenant, never
  global); no viewer, or anything that is not a user, sees nothing. The live feed is
  subscription-scoped to a tenant's own site, so global/other-site broadcasts never
  reach a tenant here; the per-resource "own + global" rule for shared runtime
  resources is applied on the bulk DB read (see
  `MishkaCmsCore.Activity.Query.shares_globals?/1`).
  """
  def visible_to?(entry_site_id, viewer) do
    case reach(viewer) do
      :everything -> true
      {:site, site_id} -> entry_site_id == site_id
      :nothing -> false
    end
  end

  @doc """
  Heroicon name for an action atom, for the activity timeline's per-row icon.
  Covers both PaperTrail/AshEvents content actions and Oban job outcomes.
  """
  def action_icon(action) when action in [:create, :master_create], do: "hero-plus-circle"
  def action_icon(action) when action in [:update, :master_update], do: "hero-pencil-square"
  def action_icon(action) when action in [:publish, :master_publish], do: "hero-rocket-launch"
  def action_icon(action) when action in [:destroy, :master_destroy], do: "hero-archive-box"

  def action_icon(action) when action in [:permanent_destroy, :master_permanent_destroy],
    do: "hero-trash"

  def action_icon(action) when action in [:unarchive, :master_unarchive],
    do: "hero-arrow-uturn-left"

  def action_icon(:restore_version), do: "hero-clock"
  def action_icon(:completed), do: "hero-check-circle"
  def action_icon(action) when action in [:discarded, :exception], do: "hero-x-circle"
  def action_icon(:retryable), do: "hero-arrow-path"
  def action_icon(_), do: "hero-bolt"

  @doc "Tailwind `bg-/text-` classes for a badge/avatar palette tone (the timeline UI)."
  def tone_class(tone), do: Map.get(@tone_classes, tone, "bg-gray-100 text-gray-700")

  @doc """
  What the log calls each of `user_ids`, for `viewer`, as `%{user_id => label}`.

  The email of an actor `viewer` may read (see `MishkaCmsCore.Activity.Query.actor_emails/2`),
  "Master" for a master's id, "Unknown" for any other id. Two reads for the whole list. Read a label
  back with `actor_label/2`.
  """
  @spec actor_labels([String.t() | nil], map() | nil) :: %{String.t() => String.t()}
  def actor_labels(user_ids, viewer) do
    ids = user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    users = MishkaCmsCore.Activity.Query.actor_emails(ids, viewer)

    masters =
      case ids |> Enum.reject(&Map.has_key?(users, &1)) |> AccountsHelper.master_ids() do
        {:ok, masters} -> masters
        {:error, _reason} -> MapSet.new()
      end

    Map.new(ids, fn id ->
      {id, AccountsHelper.who(Map.get(users, id), MapSet.member?(masters, id), :unknown)}
    end)
  end

  @doc """
  The label `actor_labels/2` gave `user_id`: "System" for no user, "Unknown" for an id it was not
  given.
  """
  @spec actor_label(map(), String.t() | nil) :: String.t()
  def actor_label(_labels, nil), do: AccountsHelper.label(:system)

  def actor_label(labels, user_id),
    do: Map.get_lazy(labels, user_id, fn -> AccountsHelper.label(:unknown) end)

  @doc "Up to two uppercase initials for an actor display name (`\"?\"` when blank)."
  def initials(name) when is_binary(name) and name != "" do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", fn word -> word |> String.first() |> String.upcase() end)
  end

  def initials(_), do: "?"

  @doc "Deterministic palette tone for an avatar, derived from any seed value."
  def avatar_tone(seed) do
    Enum.at(@avatar_tones, :erlang.phash2(seed, length(@avatar_tones)))
  end
end
