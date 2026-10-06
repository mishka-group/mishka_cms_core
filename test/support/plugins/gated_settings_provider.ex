defmodule MishkaCmsCore.Test.Plugins.GatedSettingsProvider do
  @moduledoc """
  Example provider: an extension whose setting is behind an ACL — it declares a `permission`, so only
  a user holding that permission sees it (and the tab it lives on). Listed through
  `config :mishka_cms, :settings_providers`, the config-file half of the registry.

  See `MishkaCmsCore.Settings.define/3`.
  """
  alias MishkaCmsCore.Settings

  @permission "admin:dashboard:setting:secret"
  @admin_permission "admin:*"

  @doc "The permission gating `secret.token` — the one a test grants or withholds."
  def permission, do: @permission

  @doc """
  The permission gating `vault.key`: full admin of both surfaces, which no dashboard name covers — so
  a full dashboard admin, who reaches every screen, still may not write it.
  """
  def admin_permission, do: @admin_permission

  def definitions do
    [
      Settings.define("secret.token", :string,
        default: "s3cret",
        category: "deploy",
        scope: :master,
        source: :extension,
        label: "Deploy token",
        permission: @permission
      ),
      Settings.define("vault.key", :string,
        default: "v4ult",
        category: "vault",
        scope: :master,
        source: :extension,
        label: "Vault key",
        permission: @admin_permission
      )
    ]
  end
end
