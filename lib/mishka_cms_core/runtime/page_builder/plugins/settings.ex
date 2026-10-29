# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.Settings do
  @moduledoc """
  The editor's own settings, registered on `settings:register` (`MishkaCmsCore.Settings`).

  WHAT THE EDITOR WRITES FOR ITSELF. The Studio's switches (`cms_builder.studio.*`) and the
  component presets (`cms_builder.preset.<component>`) are keys no definition names, one per site
  and per component. One `match: :prefix` definition covers every `cms_builder.` key, and only its
  `:permission` is read: any name that opens a builder writes them, a runtime area of a document the
  editor edits or `admin:dashboard:code`, and the setting area alone does not. Without the editor
  such a key takes `admin:dashboard:setting`, which fails closed.

  THE MENTION NOTIFICATION'S TWO SWITCHES. Writing `@someone` in a review note notifies them
  (`MishkaCmsCore.Runtime.PageBuilder.Mentions`); a site turns that off under Notifications and a
  person turns their own copy off under Preferences. Both keys follow the notification type, as
  `MishkaCmsCore.Notify.Delivery` reads them.
  """
  use MishkaInstaller.Event.Hook, event: "settings:register", initial: %{priority: 50}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Runtime.PageBuilder.Mentions
  alias MishkaCmsCore.Settings

  @prefix "cms_builder."

  # The names that open a builder: the runtime area of each document the editor edits, and the code
  # area, which opens every one of them.
  @opens [
    "admin:dashboard:runtime:page",
    "admin:dashboard:runtime:layout",
    "admin:dashboard:runtime:component",
    "admin:dashboard:runtime:error_page",
    "admin:dashboard:code"
  ]

  @doc "The names that open a builder, any one of which writes a `cms_builder.` key."
  @spec opens() :: [String.t()]
  def opens, do: @opens

  @impl true
  def call(%{definitions: definitions} = state) when is_list(definitions),
    do: {:reply, %{state | definitions: definitions ++ definitions()}}

  def call(state), do: {:reply, state}

  @doc "The definitions this plugin contributes."
  @spec definitions() :: [Settings.definition()]
  def definitions do
    type = Mentions.notification_type()

    [
      Settings.define(@prefix, :string,
        match: :prefix,
        permission: @opens,
        category: "builder",
        source: :plugin,
        editable?: false
      ),
      Settings.define(Notify.setting_key(type), :boolean,
        default: true,
        category: "notifications",
        group: gettext_noop("Events"),
        scope: :both,
        source: :plugin,
        label: gettext_noop("Notify people named in a review note"),
        description:
          gettext_noop("Writing @someone in the visual editor's Review panel tells them.")
      ),
      Notify.user_pref_definition(
        type,
        gettext_noop("Being named in a review note"),
        gettext_noop("Tell me when somebody writes my name in a note in the visual editor.")
      )
    ]
  end
end
