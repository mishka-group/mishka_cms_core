# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SeedProbe do
  @moduledoc """
  Test plugin for `installer:seed`. Under the key `"mishka_seed_probe"` it sends each payload it is
  handed to the calling process as `{:seed, payload}`, writes one progress line and reports the site
  and the part, the way an extension's part answers. Its `"refused"` part reports `%{error: :refused}`,
  as a part that caught its own failure does; under `"mishka_seed_raises"` every part raises.
  """
  use MishkaInstaller.Event.Hook, event: "installer:seed"

  @impl true
  def call(%{key: "mishka_seed_probe", part: "refused"} = payload) do
    send(self(), {:seed, payload})
    {:reply, %{payload | reports: payload.reports ++ [%{error: :refused}]}}
  end

  def call(%{key: "mishka_seed_probe", reports: reports} = payload) do
    send(self(), {:seed, payload})
    payload.progress.("seeded #{payload.site_id}")

    {:reply, %{payload | reports: reports ++ [%{site_id: payload.site_id, part: payload.part}]}}
  end

  def call(%{key: "mishka_seed_raises"}), do: raise("the probe's part failed")

  def call(payload), do: {:reply, payload}
end
