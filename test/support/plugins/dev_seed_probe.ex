# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.DevSeedProbe do
  @moduledoc """
  Test plugin for `dev:seed` under the key `"mishka_seed_probe"`: it sends the payload it was handed
  to the calling process as `{:dev_seed, payload}`, writes one progress line, and reports, the way
  an extension's dev seed answers. Under `"mishka_seed_raises"` it raises, as a broken seed would.
  """
  use MishkaInstaller.Event.Hook, event: "dev:seed"

  @impl true
  def call(%{key: "mishka_seed_probe", reports: reports} = payload) do
    send(self(), {:dev_seed, payload})
    payload.progress.("seeded #{payload.site_id}")

    {:reply, %{payload | reports: reports ++ [%{site_id: payload.site_id}]}}
  end

  def call(%{key: "mishka_seed_raises"}), do: raise("the probe's seed failed")

  def call(payload), do: {:reply, payload}
end
