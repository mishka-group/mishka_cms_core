import Config

config :mishka_cms_core,
  ecto_repos: [MishkaCmsCore.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    MishkaCmsCore.Runtime,
    MishkaCmsCore.Accounts,
    MishkaCmsCore.Mail
  ]

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :ash,
  default_string_length_count: :codepoints,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :tokens,
        :postgres,
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:json_api, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

# Which repo the resources write through and which endpoint they broadcast on. Every Ash resource
# here reads these with `Application.compile_env!/2` — the CMS and each extension set them to their
# own; on its own this library uses the ones below. Compile-time, so nothing is paid per query.
# Whose admin routes `extension_routes(:admin)` mounts. In the CMS this lists every installed
# extension; on its own this library has only itself.
config :mishka_cms_core, extensions: [MishkaCmsCoreWeb]

config :mishka_cms_core,
  repo: MishkaCmsCore.Repo,
  endpoint: MishkaCmsCore.TestEndpoint,
  host_app: :mishka_cms_core

# JSON:API speaks `application/vnd.api+json`, which Plug does not know by default — without this the
# `:accepts ["json"]` plug answers 406. `:mime` reads this at compile time, so changing it needs
# `mix deps.compile mime --force`.
config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

# Kept out of every request and LiveView event log: a parameter whose name holds one of these words
# — an account password, a provider's API key (`mailer.resend.api_key`), a sign-in token.
config :phoenix, :filter_parameters, ["password", "secret", "api_key", "token"]

import_config "#{config_env()}.exs"
