# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config

# A BUNDLE A DEVELOPER PLACED BY HAND WINS HERE, until a version is picked in the installer.
# Production looks up the newest release instead, so a stale file in an image cannot stand in for it —
# see `MishkaCmsCore.Runtime.Handlers.UiKitHandler.prefer_local?/0`. Both environments still fall
# back to the other source, so neither dead-ends.
config :mishka_cms_core, :prefer_local_ui_kits, true
