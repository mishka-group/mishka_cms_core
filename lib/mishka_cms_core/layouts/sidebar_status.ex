# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.SidebarStatus do
  @moduledoc """
  What each part of the CMS tells the admin about at the bottom of the sidebar, on the
  `"sidebar:status"` mishka_installer event: "8 failed jobs", "3 unhandled provider events", "A
  new version is out". Every part answers for itself, so the sidebar never says anything a part did
  not count. The lines are drawn as one card above the sidebar's footer entries
  (`MishkaCmsCore.Layouts.status_card/1`):

    * no line, and at least one plugin ran a check the viewer may see (it set `checked: true`): a
      green card "All systems operational" that says when the check ran ("Checked 1 min ago",
      `checked_label/2`);
    * only `:info` lines: a blue card "1 note" over the first line's words;
    * any `:warn` or `:error` line: a card "2 issues" in the worst line's tone (amber or red) over
      that line's words ("27 failed jobs");
    * no plugin checked and no line: no card at all.

  One line with a link opens its page; several open the list of the lines, each opening its page,
  beside the sidebar on a wide screen and as a sheet on a phone. The title is `title/1` and can be
  changed by a plugin on `"sidebar:status:card"` (below).

  A line is a map:

    * `id`: a string, unique and stable;
    * `level`: `:info`, `:warn` or `:error`;
    * `label`: the line's few words, already translated: "8 failed jobs";
    * `count`: optional, the number the label says, a whole number;
    * `link`: optional, a path of this app the line opens
      (`MishkaCmsCore.Layouts.TopbarNeeds.local_path/1`); anything else is dropped;
    * `permission`: optional, one name or a list where holding ANY is enough
      (`MishkaCmsCore.Settings.permitted?/2`);
    * `site_id`: optional, the site the line is about.

  A line with no `id`, no `label`, an unknown `level` or an `id` already taken is dropped, and so
  is a line the viewer may not see: one behind a permission they do not hold, or, for an admin of
  one site, a line of another site. A master sees every site's lines; a line of a site other than
  the one the page is on carries that site's name ("8 failed jobs · Shop"). The lines are sorted
  worst first: `:error`, `:warn`, then `:info`.

  ## Checked

  A plugin that ran its check for this viewer sets `checked: true`, whether or not it found a
  problem; that is what lets the card say "All systems operational" rather than nothing. A plugin
  sets it only when the viewer may see what it checks (the permission of its lines), so a viewer
  with no check of their own sees no card at all.

  ## What a plugin is handed

      %{
        lines: [line],
        checked: false,          # set to true by a plugin that ran its check
        current_user: user,      # with :permissions loaded; a master has no site_id
        current_site: site,      # the site the request resolved to, or nil
        current_path: "/admin/dashboard/...",
        view: module(),
        window: 3_600,           # seconds a plugin counts back
        since: DateTime.t()      # now less the window
      }

  It answers `{:reply, %{data | lines: lines ++ mine, checked: true}}` when it ran its check, or the
  map as it came when it did not (the viewer may not see it). Each answer should be one count, kept a
  short while with `cached/2`:

      defmodule MyShop.FailedOrders do
        use MishkaInstaller.Event.Hook, event: "sidebar:status"

        alias MishkaCmsCore.Layouts.SidebarStatus

        @impl true
        def call(%{lines: lines, current_user: %{site_id: site_id} = user, since: since} = data)
            when is_binary(site_id) do
          if MishkaCmsCore.Settings.permitted?(%{permission: "admin:dashboard:shop"}, user) do
            case SidebarStatus.cached({site_id, "shop.failed"}, fn -> MyShop.failed(site_id, since) end) do
              0 ->
                {:reply, %{data | checked: true}}

              count ->
                line = %{id: "shop-failed", level: :error, label: "\#{count} failed orders",
                         count: count, link: "/admin/dashboard/shop/orders?failed=true",
                         permission: "admin:dashboard:shop", site_id: site_id}

                {:reply, %{data | lines: lines ++ [line], checked: true}}
            end
          else
            {:reply, data}
          end
        end

        def call(data), do: {:reply, data}
      end

  A note that is not a problem is a line of level `:info`, such as `%{id: "shop-update", level:
  :info, label: "Shop 2.1 is out", link: "/admin/dashboard/extensions"}`.

  ## Changing the card

  Once the lines are collected, the card drawn from them (`card/2`) goes through a second event,
  `"sidebar:status:card"`, so a host or a plugin can change what it says or hide it. A plugin there
  is handed

      %{
        card: %{level: :warn, title: "2 issues", detail: "27 failed jobs"},  # or nil: no card
        lines: [line],           # the lines as collected, worst first
        current_user: user,
        current_site: site,
        current_path: "/admin/dashboard/...",
        view: module()
      }

  and answers the map with its own `card`: another `title` or `detail` (both already translated),
  another `level` (`:ok`, `:info`, `:warn` or `:error`), or `nil` to draw no card for this viewer.
  A card the plugin broke (no title, an unknown level) is drawn as it came. On an `:ok` card a
  `detail` of `nil` keeps "Checked 1 min ago". What a press on the card does still follows the
  lines: one line's page, or the list of several.

      defmodule MyHost.StatusCard do
        use MishkaInstaller.Event.Hook, event: "sidebar:status:card"

        use Gettext, backend: MyHost.Gettext

        @impl true
        def call(%{current_user: %{site_id: nil}} = data), do: {:reply, %{data | card: nil}}

        def call(%{card: %{level: :ok} = card} = data),
          do: {:reply, %{data | card: %{card | title: gettext("Everything is running")}}}

        def call(data), do: {:reply, data}
      end

  Here a master sees no card, and everyone else reads "Everything is running" when all is well.

  ## When it is called

  `MishkaCmsCore.Layouts.Nav` asks both events when an admin page opens and when its path changes,
  never on a render, so a plugin's count is read at most once a page and, through `cached/2`, at
  most once in `@ttl_ms` for all the pages open on a site. A part whose count changed calls
  `changed/1` with the site: the kept counts of that site are dropped and every open page of it asks
  again, once for a burst of changes. A plugin that raises is logged by mishka_installer and the card
  is drawn without its line.

  ## Options

      config :mishka_cms_core, :sidebar_status,
        enabled: true,
        window: 3_600,
        levels: [:info, :warn, :error]

  `enabled: false` draws no card and asks no plugin. `window` is how many seconds back a plugin
  counts (the last hour by default), handed to plugins as `window` and `since`. `levels` are the
  levels of the lines shown, all three by default: `levels: [:warn, :error]` hides the notes, and
  with no other line the card says "All systems operational" when a plugin checked.
  """
  use GenServer
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Layouts.TopbarNeeds
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings

  @event "sidebar:status"
  @card_event "sidebar:status:card"
  @activity "/admin/dashboard/runtime/activity"
  @activity_permission "admin:dashboard:runtime:activity"
  @topic "sidebar:status"
  @table :mishka_cms_sidebar_status
  @levels [:info, :warn, :error]
  @card_levels [:ok | @levels]
  @ttl_ms 30_000
  @window 3_600

  @type line :: %{
          required(:id) => String.t(),
          required(:level) => level(),
          required(:label) => String.t(),
          optional(:count) => non_neg_integer() | nil,
          optional(:link) => String.t() | nil,
          optional(:permission) => String.t() | [String.t()],
          optional(:site_id) => String.t() | nil,
          optional(:checked_at) => DateTime.t()
        }

  @type level :: :ok | :info | :warn | :error

  @type card :: %{
          required(:level) => level(),
          required(:title) => String.t(),
          required(:detail) => String.t() | nil
        }

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "The mishka_installer event parts add their lines on."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The mishka_installer event a plugin changes or hides the card on (`card/2`)."
  @spec card_event() :: String.t()
  def card_event, do: @card_event

  @doc "The PubSub topic `changed/1` is announced on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Whether the row is drawn (`config :mishka_cms_core, :sidebar_status, enabled:`), on by default."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(options(), :enabled, true) != false

  @doc "How many seconds back a plugin counts (`config :mishka_cms_core, :sidebar_status, window:`), 3600 by default."
  @spec window() :: pos_integer()
  def window do
    case Keyword.get(options(), :window, @window) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _other -> @window
    end
  end

  @doc """
  The levels of the lines shown (`config :mishka_cms_core, :sidebar_status, levels:`), `:info`,
  `:warn` and `:error` by default; a level not among them is left out.
  """
  @spec levels() :: [:info | :warn | :error]
  def levels do
    case Keyword.get(options(), :levels, @levels) do
      levels when is_list(levels) -> Enum.filter(@levels, &(&1 in levels))
      _other -> @levels
    end
  end

  defp options, do: Application.get_env(:mishka_cms_core, :sidebar_status, [])

  @doc """
  The lines to show for `context`, the worst first (`:error`, `:warn`, then `:info`), `id` breaking
  a tie; each one the context's `current_user` may see, of a level `levels/0` shows. With no such
  line and a plugin that checked, the one `:ok` line (`all_clear/1`). `[]` when the card is off, no
  plugin checked or answered, or one raised.
  """
  @spec collect(map()) :: [line()]
  def collect(%{current_user: user} = context) do
    with true <- enabled?() and not is_nil(user),
         %{lines: lines} = answer when is_list(lines) <-
           MishkaInstaller.Event.Hook.call(@event, data(context)) do
      current = if is_nil(user.site_id), do: current_site_id(context), else: user.site_id
      shown = levels()

      lines
      |> Enum.filter(
        &(line?(&1, shown) and Settings.permitted?(&1, user) and in_reach?(&1, user))
      )
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(&clean(&1, current))
      |> Enum.sort_by(&{-rank(&1.level), &1.id})
      |> clear(answer[:checked] == true, user)
    else
      _nothing -> []
    end
  end

  defp clear([], true, user), do: [all_clear(user)]
  defp clear(lines, _checked, _user), do: lines

  @doc """
  The neutral line returned when the plugins checked and found nothing: level `:ok`, which the card
  draws as "All systems operational". It names the activity log as
  its link for a viewer who may open it (no link for anyone else), and `checked_at`, the moment the
  plugins were asked.
  """
  @spec all_clear(map() | nil) :: line()
  def all_clear(user) do
    link = if Settings.permitted?(%{permission: @activity_permission}, user), do: @activity

    %{
      id: "all-clear",
      level: :ok,
      label: gettext("OK"),
      count: nil,
      link: link,
      site_id: nil,
      checked_at: DateTime.utc_now()
    }
  end

  defp data(context) do
    window = window()

    context
    |> Map.put(:lines, [])
    |> Map.put(:checked, false)
    |> Map.put(:window, window)
    |> Map.put(:since, DateTime.add(DateTime.utc_now(), -window, :second))
  end

  @doc """
  The value of `fun` kept for a short while under `key`, read straight from memory while it is
  kept. `key` is `{site_id, name}` (`nil` as the site for a count of every site), so `changed/1`
  drops the counts of one site.
  """
  @spec cached({String.t() | nil, term()}, (-> term())) :: term()
  def cached({_site, _name} = key, fun) when is_function(fun, 0) do
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(@table) do
      :undefined ->
        fun.()

      _table ->
        case :ets.lookup(@table, key) do
          [{^key, value, until}] when until > now ->
            value

          _missing_or_old ->
            value = fun.()
            :ets.insert(@table, {key, value, now + @ttl_ms})
            value
        end
    end
  end

  @doc """
  Tells the open pages that a count of `site_id` changed: the counts kept for that site and for
  every site are dropped, and each page of a viewer it concerns asks the plugins again. `nil` is a
  change of every site.
  """
  @spec changed(String.t() | nil) :: :ok | {:error, term()}
  def changed(site_id \\ nil) do
    forget(site_id)
    Phoenix.PubSub.broadcast(MishkaCmsCore.PubSub, @topic, {:sidebar_status_changed, site_id})
  end

  defp forget(site_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _table when is_nil(site_id) ->
        :ets.delete_all_objects(@table)

      _table ->
        :ets.match_delete(@table, {{site_id, :_}, :_, :_})
        :ets.match_delete(@table, {{nil, :_}, :_, :_})
    end

    :ok
  end

  @doc "Whether a `changed/1` of `site_id` concerns `user`'s pages (`MishkaCmsCore.Layouts.TopbarNeeds.concerns?/2`)."
  @spec concerns?(map() | nil, String.t() | nil) :: boolean()
  def concerns?(user, site_id), do: TopbarNeeds.concerns?(user, site_id)

  @doc "The worst level of `lines`: `:error`, `:warn`, `:info` or `:ok`, or `nil` for none."
  @spec level([line()]) :: level() | nil
  def level([]), do: nil
  def level(lines), do: lines |> Enum.max_by(&rank(&1.level)) |> Map.fetch!(:level)

  defp rank(:error), do: 3
  defp rank(:warn), do: 2
  defp rank(:info), do: 1
  defp rank(:ok), do: 0

  defp line?(%{id: id, level: level, label: label} = line, shown)
       when is_binary(id) and id != "" and level in @levels and is_binary(label) and label != "",
       do: level in shown and count?(line[:count]) and site?(line[:site_id])

  defp line?(_other, _shown), do: false

  defp count?(nil), do: true
  defp count?(count), do: is_integer(count) and count >= 0

  defp site?(nil), do: true
  defp site?(site_id), do: is_binary(site_id)

  defp in_reach?(%{site_id: line_site}, %{site_id: own})
       when is_binary(line_site) and is_binary(own),
       do: line_site == own

  defp in_reach?(_line, _viewer), do: true

  defp clean(line, current) do
    %{
      id: line.id,
      level: line.level,
      label: label(line.label, line[:site_id], current),
      count: line[:count],
      link: TopbarNeeds.local_path(line[:link]),
      site_id: line[:site_id]
    }
  end

  defp label(label, nil, _current), do: label
  defp label(label, site_id, site_id), do: label

  defp label(label, site_id, _current) do
    case SiteState.get(site_id) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> label <> " · " <> name
      _unknown -> label
    end
  end

  defp current_site_id(%{current_site: %{id: id}}), do: id
  defp current_site_id(_context), do: nil

  @doc """
  The card drawn from `lines` (`collect/1`), handed through the `"sidebar:status:card"` event so a
  plugin may change or hide it: its `level` is the worst line's, its `title` is `title/1` and its
  `detail` the worst line's label (`nil` on an `:ok` card, drawn as "Checked 1 min ago"). `nil`, no
  card, with no line, when the card is off, or when a plugin hid it.
  """
  @spec card([line()], map()) :: card() | nil
  def card(lines, context) do
    default = default_card(lines)

    with true <- enabled?(),
         %{card: card} <-
           MishkaInstaller.Event.Hook.call(
             @card_event,
             Map.merge(context, %{card: default, lines: lines})
           ) do
      checked_card(card, default)
    else
      _nothing -> nil
    end
  end

  defp default_card([]), do: nil
  defp default_card([%{level: :ok}]), do: %{level: :ok, title: title([]), detail: nil}

  defp default_card([worst | _rest] = lines),
    do: %{level: worst.level, title: title(lines), detail: worst.label}

  defp checked_card(nil, _default), do: nil

  defp checked_card(%{level: level, title: title} = card, _default)
       when level in @card_levels and is_binary(title) and title != "" do
    case card[:detail] do
      detail when is_binary(detail) or is_nil(detail) ->
        %{level: level, title: title, detail: detail}

      _other ->
        %{level: level, title: title, detail: nil}
    end
  end

  defp checked_card(_broken, default), do: default

  @doc """
  The card's title for `lines`: "All systems operational" with no problem line, "1 note" or "2
  notes" when every line is `:info`, and "2 issues" counting the `:warn` and `:error` lines when
  there is one.
  """
  @spec title([line()]) :: String.t()
  def title(lines) do
    case {Enum.count(lines, &(&1.level in [:warn, :error])),
          Enum.count(lines, &(&1.level == :info))} do
      {0, 0} -> gettext("All systems operational")
      {0, notes} -> ngettext("%{count} note", "%{count} notes", notes)
      {issues, _notes} -> ngettext("%{count} issue", "%{count} issues", issues)
    end
  end

  @doc """
  When the check of an `:ok` line ran, against `now`: "Checked just now" within the first minute,
  then "Checked 4 min ago" and "Checked 2 h ago". `nil` for a line with no `checked_at`.
  """
  @spec checked_label(line(), DateTime.t()) :: String.t() | nil
  def checked_label(%{checked_at: %DateTime{} = at}, now) do
    case max(DateTime.diff(now, at, :minute), 0) do
      0 ->
        gettext("Checked just now")

      minutes when minutes < 60 ->
        ngettext("Checked %{count} min ago", "Checked %{count} min ago", minutes)

      minutes ->
        ngettext("Checked %{count} h ago", "Checked %{count} h ago", div(minutes, 60))
    end
  end

  def checked_label(_line, _now), do: nil
end
