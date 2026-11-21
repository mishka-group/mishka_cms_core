# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.SidebarStatus do
  @moduledoc """
  The problems each part of the CMS tells the admin about at the bottom of the sidebar, on the
  `"sidebar:status"` mishka_installer event: "8 failed jobs", "3 unhandled provider events". Every
  part answers for itself, so the sidebar never says anything a part did not count:

    * no problem line, and at least one plugin ran a check the viewer may see (it set `checked:
      true`): a small neutral row "All clear" with a green dot, opening the activity log for a viewer
      who may open it;
    * one line: a small row (a dot in the line's colour, the line's words and an arrow) that opens the
      line's page;
    * several: "3 problems", which opens a small list of the lines, each opening its page;
    * no plugin checked and no line: nothing at all.

  A line is a map:

    * `id`: a string, unique and stable;
    * `level`: `:warn` or `:error`;
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
  the one the page is on carries that site's name ("8 failed jobs · Shop").

  ## Checked

  A plugin that ran its check for this viewer sets `checked: true`, whether or not it found a
  problem; that is what lets the sidebar say "All clear" rather than nothing. A plugin sets it only
  when the viewer may see what it checks (the permission of its lines), so a viewer with no check
  of their own sees no row at all.

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

  ## When it is called

  `MishkaCmsCore.Layouts.Nav` asks when an admin page opens and when its path changes, never on a
  render, so a plugin's count is read at most once a page and, through `cached/2`, at most once in
  `@ttl_ms` for all the pages open on a site. A part whose count changed calls `changed/1` with the
  site: the kept counts of that site are dropped and every open page of it asks again, once for a
  burst of changes. A plugin that raises is logged by mishka_installer and the row is drawn without
  its line.

  ## Options

      config :mishka_cms_core, :sidebar_status, enabled: true, window: 3_600

  `enabled: false` draws no row and asks no plugin. `window` is how many seconds back a plugin
  counts (the last hour by default), handed to plugins as `window` and `since`.
  """
  use GenServer
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Layouts.TopbarNeeds
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings

  @event "sidebar:status"
  @activity "/admin/dashboard/runtime/activity"
  @activity_permission "admin:dashboard:runtime:activity"
  @topic "sidebar:status"
  @table :mishka_cms_sidebar_status
  @levels [:warn, :error]
  @ttl_ms 30_000
  @window 3_600

  @type line :: %{
          required(:id) => String.t(),
          required(:level) => :ok | :warn | :error,
          required(:label) => String.t(),
          optional(:count) => non_neg_integer() | nil,
          optional(:link) => String.t() | nil,
          optional(:permission) => String.t() | [String.t()],
          optional(:site_id) => String.t() | nil
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

  defp options, do: Application.get_env(:mishka_cms_core, :sidebar_status, [])

  @doc """
  The lines to show for `context`, the worst first (`:error`, then `:warn`), `id` breaking a tie;
  each one the context's `current_user` may see. With no problem line and a plugin that checked, the
  one `:ok` line "All clear" (`all_clear/1`). `[]` when the row is off, no plugin checked or
  answered, or one raised.
  """
  @spec collect(map()) :: [line()]
  def collect(%{current_user: user} = context) do
    with true <- enabled?() and not is_nil(user),
         %{lines: lines} = answer when is_list(lines) <-
           MishkaInstaller.Event.Hook.call(@event, data(context)) do
      current = if is_nil(user.site_id), do: current_site_id(context), else: user.site_id

      lines
      |> Enum.filter(&(line?(&1) and Settings.permitted?(&1, user) and in_reach?(&1, user)))
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
  The neutral line drawn when the plugins checked and found nothing: "All clear", level `:ok`,
  opening the activity log for a viewer who may open it (no link for anyone else).
  """
  @spec all_clear(map() | nil) :: line()
  def all_clear(user) do
    link = if Settings.permitted?(%{permission: @activity_permission}, user), do: @activity

    %{
      id: "all-clear",
      level: :ok,
      label: gettext("All clear"),
      count: nil,
      link: link,
      site_id: nil
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

  @doc "The worst level of `lines`: `:error`, `:warn` or `:ok`, or `nil` for none."
  @spec level([line()]) :: :ok | :warn | :error | nil
  def level([]), do: nil
  def level(lines), do: lines |> Enum.max_by(&rank(&1.level)) |> Map.fetch!(:level)

  defp rank(:error), do: 2
  defp rank(:warn), do: 1
  defp rank(:ok), do: 0

  defp line?(%{id: id, level: level, label: label} = line)
       when is_binary(id) and id != "" and level in @levels and is_binary(label) and label != "",
       do: count?(line[:count]) and site?(line[:site_id])

  defp line?(_other), do: false

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

  @doc "The words of the row that opens the list of several lines: \"3 problems\"."
  @spec problems_label([line()]) :: String.t()
  def problems_label(lines),
    do: ngettext("%{count} problem", "%{count} problems", length(lines))
end
