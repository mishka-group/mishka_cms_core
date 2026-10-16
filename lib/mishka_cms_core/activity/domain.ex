# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Domain do
  @moduledoc """
  Ash domain for the synthetic, read-only `MishkaCmsCore.Activity.ActivityEntry`
  resource that backs the gervaz activity-log table. Not registered in
  `:ash_domains` (no migrations / DB layer) — it exists only so the resource has
  a domain for `Ash.read`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource MishkaCmsCore.Activity.ActivityEntry
  end
end
