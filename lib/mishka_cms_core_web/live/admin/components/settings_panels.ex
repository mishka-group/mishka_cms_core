# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.SettingsPanels do
  @moduledoc """
  The tabs an extension adds to the settings page, on the `"settings:panels"` mishka_installer
  event, as a card is added to the Preferences tab on `"account:security:cards"` (`SecurityCards`).
  The core adds none itself: a tab is drawn only while some plugin answers.

  A panel is `%{id: String.t(), label: String.t(), icon: String.t(), priority: integer(), ...}`
  plus what draws it, one of:

    * `module: module()` — a LiveComponent, drawn with `id` and `current_user`;
    * `render: (assigns -> Phoenix.LiveView.Rendered.t())` — a function component, called with
      `%{id: id, current_user: user}`.

  It may also carry a `description:` shown under the label. `id` is the tab's address
  (`/admin/dashboard/settings?tab=<id>`), so it must not be a settings category's name; low
  `priority` comes first, after the settings categories.

  A plugin is handed `%{panels: [], current_user: user}` and answers `{:reply, %{panels: panels}}`
  with its own added. It sees who is asking, so it may answer nothing for a user who may not use
  its tab. A panel with a missing field, an `id` already taken or neither (or both) of `module` and
  `render` is dropped.

      use MishkaInstaller.Event.Hook, event: "settings:panels"

      def call(%{panels: panels, current_user: user} = data),
        do: {:reply, %{data | panels: panels ++ [panel(user)]}}

      defp panel(_user),
        do: %{id: "import", label: "Import", icon: "hero-arrow-down-tray", priority: 10, module: MyApp.ImportPanel}
  """

  @type panel :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:icon) => String.t(),
          required(:priority) => integer(),
          optional(:description) => String.t(),
          optional(:module) => module(),
          optional(:render) => (map() -> term())
        }

  @event "settings:panels"

  @doc """
  The panels to draw for `user`, low priority first. `taken` is the ids already used by the page's
  own tabs; a panel with one of them is dropped.
  """
  @spec collect(map() | nil, [String.t()]) :: [panel()]
  def collect(user, taken \\ []) do
    case MishkaInstaller.Event.Hook.call(@event, %{panels: [], current_user: user}) do
      %{panels: panels} when is_list(panels) ->
        panels
        |> Enum.filter(&(panel?(&1) and &1.id not in taken))
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{&1.priority, &1.id})

      _nothing ->
        []
    end
  end

  defp panel?(%{id: id, label: label, icon: icon, priority: priority} = panel)
       when is_binary(id) and is_binary(label) and is_binary(icon) and is_integer(priority),
       do: drawn_by?(panel)

  defp panel?(_other), do: false

  defp drawn_by?(%{module: module} = panel) when is_atom(module) and not is_nil(module),
    do: not is_map_key(panel, :render)

  defp drawn_by?(%{render: render} = panel) when is_function(render, 1),
    do: not is_map_key(panel, :module)

  defp drawn_by?(_panel), do: false
end
