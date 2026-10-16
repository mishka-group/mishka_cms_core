# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install do
  @moduledoc """
  First-run install state, kept in `:persistent_term` so the per-request install gate is a
  lock-free RAM read — never a per-request database count.

  The database is the source of truth; this is only the boot-loaded mirror. `BootHandler`
  calls `refresh!/0` once at boot, the installer calls `mark_installed!/0` when the wizard
  commits, and a fresh database (no master user and no site) re-opens `/install` on the next
  boot. The key is absent until boot computes it (and in the test environment, where
  `BootHandler` does not run) — `status/0` reports `:unknown` then, so the gate stays inert
  rather than guessing.

  See `MishkaCms.Plugs.InstallGate`.
  """
  require Ash.Query

  @key :mishka_installed

  @typedoc "Install state as seen by the gate."
  @type status :: :installed | :not_installed | :unknown

  @doc """
  Returns `:installed`, `:not_installed`, or `:unknown`. `:unknown` means boot has not yet
  computed the flag (or we are in a test environment) — callers should treat it as "do nothing".
  """
  @spec status() :: status()
  def status do
    case :persistent_term.get(@key, :unknown) do
      true -> :installed
      false -> :not_installed
      _ -> :unknown
    end
  end

  @doc "Whether first-run install has completed (a master user and at least one site exist)."
  @spec installed?() :: boolean()
  def installed?, do: :persistent_term.get(@key, false) == true

  @doc "Recomputes install state from the database and caches it. Returns the boolean."
  @spec refresh!() :: boolean()
  def refresh! do
    installed? = master_user_exists?() and site_exists?()
    :persistent_term.put(@key, installed?)
    installed?
  end

  @doc "Marks the CMS installed — called once when the wizard commits. No reboot needed."
  @spec mark_installed!() :: :ok
  def mark_installed!, do: :persistent_term.put(@key, true)

  defp site_exists?, do: Ash.count!(MishkaCmsCore.Runtime.Site, authorize?: false) > 0

  defp master_user_exists? do
    MishkaCmsCore.Accounts.User
    |> Ash.Query.filter(is_nil(site_id))
    |> Ash.count!(authorize?: false) > 0
  end
end
