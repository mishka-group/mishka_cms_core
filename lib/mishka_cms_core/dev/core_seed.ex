# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.CoreSeed do
  @moduledoc """
  The core's own seed, as a plugin on `dev:seed` (`MishkaCmsCore.Dev.Seeds`) like every extension's:
  the sites, users, permissions, UI kits, layouts, pages and content the other seeds build on.

  It is `required: true` and at priority 0, so `MishkaCmsCore.Dev.Seeds.categories/0` lists it first
  and `MishkaCmsCore.Dev.Seeds.run/2` runs it whatever was chosen. It runs once, not per site, and
  its report is the foundation map the per-site seeds are fired with: `dev_seed/1`'s at `size: :dev`
  and `stress_seed/1`'s, given the run's `opts`, at `size: :stress`. Registered in
  MishkaCmsCore.Application.
  """
  use MishkaInstaller.Event.Hook,
    event: "dev:seed",
    initial: %{
      priority: 0,
      extra: [
        %{
          label: "Mishka CMS",
          summary: "Sites, users, permissions, UI kits, layouts, pages and content",
          required: true
        }
      ]
    }

  alias MishkaCmsCore.Dev.Seeds

  @impl true
  def call(%{key: "mishka_cms_core", size: :dev, progress: line, reports: reports} = payload) do
    foundation = Seeds.dev_seed(fn {_phase, _status, text} -> line.(text) end)

    {:reply, %{payload | reports: reports ++ [foundation]}}
  end

  def call(%{key: "mishka_cms_core", size: :stress, opts: opts, reports: reports} = payload) do
    foundation = Seeds.stress_seed(opts)

    {:reply, %{payload | reports: reports ++ [foundation]}}
  end

  def call(payload), do: {:reply, payload}
end
