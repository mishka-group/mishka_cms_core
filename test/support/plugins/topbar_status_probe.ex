# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.TopbarStatusProbe do
  @moduledoc """
  Test plugin on `topbar:status`: an `:ok` line and a `:warn` line with a link, out of order, plus a
  line behind a permission the test admin does not hold, a line of an unknown level, a line with
  no label, a line whose link leaves the app and a second line reusing a taken id. The page shows
  the warn line first, then the ok one, the leaving link dropped.
  """
  use MishkaInstaller.Event.Hook, event: "topbar:status"

  @impl true
  def call(%{lines: lines} = data) do
    extra = [
      %{id: "probe-ok", level: :ok, label: "Backups ran", detail: "Last night at 2:00."},
      %{
        id: "probe-warn",
        level: :warn,
        label: "Sandbox",
        detail: "Nothing is charged.",
        link: "/admin/dashboard/settings"
      },
      %{id: "probe-gated", level: :error, label: "Secret", permission: "admin:api:probe"},
      %{id: "probe-odd", level: :purple, label: "Odd"},
      %{id: "probe-bare", level: :warn},
      %{id: "probe-away", level: :ok, label: "Away", link: "https://evil.example/x"},
      %{id: "probe-ok", level: :error, label: "Taken id"}
    ]

    {:reply, %{data | lines: lines ++ extra}}
  end
end
