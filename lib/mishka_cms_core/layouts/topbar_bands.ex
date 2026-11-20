# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.TopbarBands do
  @moduledoc """
  The bands an extension draws full width under the admin top bar, on the `"topbar:bands"`
  mishka_installer event, as its buttons come on `"topbar:items"`
  (`MishkaCmsCore.Layouts.TopbarItems`). A band is for what holds on every page of the extension
  while a condition is true: "you are looking at every site", "live updates are paused". The core
  draws none itself, and draws nothing under the top bar while no plugin answers.

  A band is `%{id: String.t(), priority: integer()}` plus what draws it, as an item is: a
  LiveComponent `module:` or a `render:` function taking one argument; it may carry a `permission:`
  as an item may. A band is drawn with `id`, `current_user`, `current_site`, `current_path` and
  `view`, and a LiveComponent keeps its own state, so it follows a live change itself (it is
  updated with `Phoenix.LiveView.send_update/3`).

  ## What a plugin is handed

      %{
        bands: [band],
        current_user: user,      # with :permissions loaded; a master has no site_id
        current_site: site,      # the site the request resolved to, or nil
        current_path: "/admin/dashboard/...",
        view: module()
      }

  It answers `{:reply, %{data | bands: bands ++ mine}}`, and answers nothing for a user, a site or a
  page it has no band for. Low `priority` comes first, `id` breaks a tie, and a band with a missing
  field, a taken `id` or no way to draw it is dropped.

  ## When it is called

  `MishkaCmsCore.Layouts.Nav` asks when an admin page opens and when its path changes, never on a
  render. A plugin that raises is logged by mishka_installer and the page is drawn with no band.
  """

  alias MishkaCmsCore.Settings
  alias MishkaCmsCoreWeb.Live.Admin.Components.SettingsPanels

  @type band :: %{
          required(:id) => String.t(),
          required(:priority) => integer(),
          optional(:permission) => String.t() | [String.t()],
          optional(:module) => module(),
          optional(:render) => (map() -> term())
        }

  @type context :: %{
          current_user: map() | nil,
          current_site: map() | nil,
          current_path: String.t() | nil,
          view: module() | nil
        }

  @event "topbar:bands"

  @doc "The mishka_installer event extensions add their bands on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The bands to draw for `context`, low priority first, each one the context's `current_user` may see.
  `[]` when no plugin answers, when every band was dropped and when a plugin raised.
  """
  @spec collect(context()) :: [band()]
  def collect(%{current_user: user} = context) do
    case MishkaInstaller.Event.Hook.call(@event, Map.put(context, :bands, [])) do
      %{bands: bands} when is_list(bands) ->
        bands
        |> Enum.filter(&(band?(&1) and Settings.permitted?(&1, user)))
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{&1.priority, &1.id})

      _nothing ->
        []
    end
  end

  defp band?(%{id: id, priority: priority} = band)
       when is_binary(id) and id != "" and is_integer(priority),
       do: SettingsPanels.drawn_by?(band)

  defp band?(_other), do: false
end
