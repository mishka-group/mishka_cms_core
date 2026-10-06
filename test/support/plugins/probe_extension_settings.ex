defmodule MishkaCmsCore.Test.Plugins.ProbeExtensionSettings do
  @moduledoc """
  Example provider: the two per-site settings an extension adds for itself
  (`MishkaCmsCore.Install.Extensions.settings/2`), for an extension named `mishka_probe`. Listed
  through `config :mishka_cms, :settings_providers`.
  """

  def definitions, do: MishkaCmsCore.Install.Extensions.settings(:mishka_probe, "probe")
end
