# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.TopbarItems do
  @moduledoc """
  The items an extension adds to the admin top bar, on the `"topbar:items"` mishka_installer event,
  as a tab is added to the settings page on `"settings:panels"`
  (`MishkaCmsCoreWeb.Live.Admin.Components.SettingsPanels`). The core adds none itself: the top bar
  draws its slot only while some plugin answers, so with no plugin it is drawn as it always was.

  An item is `%{id: String.t(), priority: integer()}` plus what draws it, one of:

    * `module: module()` — a LiveComponent, drawn with `id` and the context below;
    * `render: (assigns -> Phoenix.LiveView.Rendered.t())` — a function component, called with
      `%{id: id}` and the context below.

  It may also carry a `permission:`, one name or a list of them where holding ANY is enough, checked
  as a dashboard widget's is (`MishkaCmsCore.Settings.permitted?/2`); without one, every signed-in
  admin sees it. Low `priority` comes first, `id` breaks a tie. `id` is the LiveComponent's id and
  part of the DOM id of the item's wrapper, `topbar-item-<id>`, so keep it unique and stable. An item
  with a missing field, an `id` already taken, or neither (or both) of `module` and `render` is
  dropped.

  ## What a plugin is handed

      %{
        items: [item],
        current_user: user,      # with :permissions loaded; a master has no site_id
        current_site: site,      # the site the request resolved to, or nil
        current_path: "/admin/dashboard/...",
        view: module()           # the admin LiveView of the page
      }

  It answers `{:reply, %{data | items: items ++ mine}}`, and may answer nothing for a user, a site
  or a page it has no item for. A drawn item gets the same `current_user`, `current_site`,
  `current_path` and `view` as assigns, so a LiveComponent keeps its own state (an open list, a
  search query) and loads its own data.

      defmodule MyExtension.TopbarItems do
        use MishkaInstaller.Event.Hook, event: "topbar:items"

        @impl true
        def call(%{items: items, current_user: %{site_id: nil}} = data) do
          item = %{id: "my-extension-live", priority: 10, module: MyExtension.LiveToggle}
          {:reply, %{data | items: items ++ [item]}}
        end

        def call(data), do: {:reply, data}
      end

  ## When it is called

  `MishkaCmsCore.Layouts.Nav` asks once when an admin page opens, and again only when the page's path
  changes; a render of the top bar calls no plugin. A plugin that raises is logged by
  mishka_installer and the event answers its seed, so the top bar is drawn with no item and the page
  still opens.
  """

  alias MishkaCmsCore.Settings
  alias MishkaCmsCoreWeb.Live.Admin.Components.SettingsPanels

  @type item :: %{
          required(:id) => String.t(),
          required(:priority) => integer(),
          optional(:permission) => String.t() | [String.t()],
          optional(:module) => module(),
          optional(:phone) => boolean(),
          optional(:render) => (map() -> term())
        }

  @type context :: %{
          current_user: map() | nil,
          current_site: map() | nil,
          current_path: String.t() | nil,
          view: module() | nil
        }

  @event "topbar:items"

  @doc "The mishka_installer event extensions add their top bar items on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The items to draw for `context`, low priority first, each one the context's `current_user` may
  see. Returns `[]` when no plugin answers, when every plugin's item was dropped, and when a plugin
  raised.
  """
  @spec collect(context()) :: [item()]
  def collect(%{current_user: user} = context) do
    case MishkaInstaller.Event.Hook.call(@event, Map.put(context, :items, [])) do
      %{items: items} when is_list(items) ->
        items
        |> Enum.filter(&(item?(&1) and Settings.permitted?(&1, user)))
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{&1.priority, &1.id})

      _nothing ->
        []
    end
  end

  defp item?(%{id: id, priority: priority} = item)
       when is_binary(id) and id != "" and is_integer(priority),
       do: SettingsPanels.drawn_by?(item)

  defp item?(_other), do: false
end
