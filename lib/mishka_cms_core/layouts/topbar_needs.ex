# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.TopbarNeeds do
  @moduledoc """
  What needs a person, listed in the top bar's bell under "What needs you", on the `"topbar:needs"`
  mishka_installer event. An extension adds its own items there, as it adds a top bar item on
  `"topbar:items"` (`MishkaCmsCore.Layouts.TopbarItems`): open disputes, refund requests, events
  not handled. The core adds one itself, the runtime jobs that failed
  (`MishkaCmsCore.Activity.Sources.Oban.failed_count/1`), for whoever may open the activity log.

  The bell's badge counts the items' `count`s, plus the viewer's unread notifications
  (`MishkaCmsCore.Notify.LiveHooks`).

  An item is a map:

    * `id` — a string, unique and stable: part of the DOM id of its row, `topbar-need-<id>`;
    * `title` — what needs the person, already translated: "A dispute needs your answer";
    * `count` — how many, an integer; an item of 0 is not listed;
    * `detail` — optional, the line under the title: "MS-4795 · 5 days left";
    * `tone` — optional, `:info` (the default), `:warn`, `:error` or `:success`: the colour of its dot;
    * `link` — optional, a path of this app the row opens (`"/admin/dashboard/shop/refunds"`); an
      address of another site, or one starting `//`, is refused and the row opens nothing;
    * `permission` — optional, one name or a list where holding ANY is enough, checked as a dashboard
      widget's is (`MishkaCmsCore.Settings.permitted?/2`); without one, every signed-in admin sees it;
    * `priority` — optional, an integer, 50 by default: low comes first, `id` breaks a tie.

  An item with no `id`, no `title`, a count that is not an integer, or an `id` already taken is
  dropped.

  ## What a plugin is handed

      %{
        needs: [item],           # the core's item is already there for a viewer who may see it
        current_user: user,      # with :permissions loaded; a master has no site_id
        current_site: site,      # the site the request resolved to, or nil
        current_path: "/admin/dashboard/...",
        view: module()
      }

  It answers `{:reply, %{data | needs: needs ++ mine}}`, counting for the viewer's own site (a
  master reads every site):

      defmodule MyShop.Needs do
        use MishkaInstaller.Event.Hook, event: "topbar:needs"

        @impl true
        def call(%{needs: needs, current_user: user} = data) do
          item = %{
            id: "shop-refunds",
            title: "A buyer asks for a refund",
            count: MyShop.Refunds.open_count(user),
            tone: :warn,
            link: "/admin/dashboard/shop/refunds",
            permission: "admin:dashboard:shop"
          }

          {:reply, %{data | needs: needs ++ [item]}}
        end
      end

  ## When it is called

  `MishkaCmsCore.Layouts.Nav` asks once when an admin page opens, again when the page's path
  changes, and again when an extension calls `changed/1`; a render of the bell calls no plugin. A
  plugin that raises is logged by mishka_installer and the event answers what it was seeded with, so
  the bell keeps the core's item and the page still opens.

  Call `changed/1` from wherever the numbers move (an order is refunded, an event fails), with the
  site they belong to: the open pages of that site's admins and of the masters ask again, the
  changes of one moment once. `changed(nil)` reaches every open page.

  ## Telemetry

    * `[:mishka_cms, :topbar_needs, :refreshed]` — emitted from the page's process each time a
      `changed/1` makes it ask again. Measurements: `%{total: integer}`, what the badge adds. Metadata:
      `%{view: module}`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Activity.Sources.Oban, as: ObanActivity
  alias MishkaCmsCore.Runtime.Redirects
  alias MishkaCmsCore.Settings

  @type tone :: :info | :warn | :error | :success

  @type item :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:count) => pos_integer(),
          required(:detail) => String.t() | nil,
          required(:tone) => tone(),
          required(:link) => String.t() | nil,
          required(:priority) => integer(),
          optional(:permission) => String.t() | [String.t()]
        }

  @type context :: %{
          current_user: map() | nil,
          current_site: map() | nil,
          current_path: String.t() | nil,
          view: module() | nil
        }

  @event "topbar:needs"
  @topic "topbar:needs"
  @tones [:info, :warn, :error, :success]
  @priority 50
  @jobs_permission "admin:dashboard:runtime:activity"

  @doc "The mishka_installer event extensions add their items to the bell on."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The `MishkaCmsCore.PubSub` topic `changed/1` speaks on and open admin pages listen to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  The items to list for `context`, low priority first, each one the context's `current_user` may see
  and with a count above 0, every optional field filled in. The core's item comes first in the
  payload, so a plugin that raises leaves it listed.
  """
  @spec collect(context()) :: [item()]
  def collect(%{current_user: user} = context) do
    case MishkaInstaller.Event.Hook.call(@event, Map.put(context, :needs, core_items(user))) do
      %{needs: needs} when is_list(needs) ->
        needs
        |> Enum.flat_map(&item/1)
        |> Enum.filter(&Settings.permitted?(&1, user))
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{&1.priority, &1.id})

      _nothing ->
        []
    end
  end

  @doc "What the items add to the bell's badge."
  @spec total([item()]) :: non_neg_integer()
  def total(needs), do: Enum.sum_by(needs, & &1.count)

  @doc """
  Tells the open admin pages that the numbers of `site_id` moved, so they ask the plugins again:
  the pages of that site's admins and of every master. `nil` reaches every open page.
  """
  @spec changed(String.t() | nil) :: :ok | {:error, term()}
  def changed(site_id \\ nil),
    do: Phoenix.PubSub.broadcast(MishkaCmsCore.PubSub, @topic, {:topbar_needs_changed, site_id})

  @doc """
  Whether a `changed/1` of `site_id` concerns `user`'s pages: always for a master and for a change
  of every site, otherwise only for the user's own site.
  """
  @spec concerns?(map() | nil, String.t() | nil) :: boolean()
  def concerns?(_user, nil), do: true
  def concerns?(%{site_id: nil}, _site_id), do: true
  def concerns?(%{site_id: site_id}, site_id), do: true
  def concerns?(_user, _site_id), do: false

  defp core_items(user) do
    with true <- Settings.permitted?(%{permission: @jobs_permission}, user),
         count when count > 0 <- ObanActivity.failed_count(user) do
      [
        %{
          id: "runtime-jobs",
          title: ngettext("%{count} job failed", "%{count} jobs failed", count),
          detail: gettext("Open the activity log to see why"),
          count: count,
          tone: :error,
          link: "/admin/dashboard/runtime/activity",
          permission: @jobs_permission,
          priority: 90
        }
      ]
    else
      _nothing -> []
    end
  end

  defp item(%{id: id, title: title, count: count} = item)
       when is_binary(id) and id != "" and is_binary(title) and title != "" and
              is_integer(count) and count > 0 do
    [
      Map.merge(item, %{
        detail: text(item[:detail]),
        tone: tone(item[:tone]),
        link: local_path(item[:link]),
        priority: priority(item[:priority])
      })
    ]
  end

  defp item(_other), do: []

  defp text(detail) when is_binary(detail) and detail != "", do: detail
  defp text(_none), do: nil

  defp tone(tone) when tone in @tones, do: tone
  defp tone(_other), do: :info

  defp priority(priority) when is_integer(priority), do: priority
  defp priority(_none), do: @priority

  @doc """
  `path` when it is a path of this app a row may open, else `nil`: never another site's address, a
  scheme-relative `//host`, nor one that decodes to either (`MishkaCmsCore.Runtime.Redirects.safe_target?/1`).
  """
  @spec local_path(term()) :: String.t() | nil
  def local_path("/" <> _rest = path) do
    if Redirects.safe_target?(path), do: path
  end

  def local_path(_other), do: nil
end
