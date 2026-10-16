# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ValidatedSettingsProvider do
  @moduledoc """
  Example provider covering the parts of a definition the settings page has to honour rather than
  merely display: a LOCKED setting (`editable?: false`), a BOUNDED integer (`min`/`max`), and a
  SELECT with a fixed option list.

  Each one is a rule the page can only enforce if it reads the declaration on the way in — a locked
  setting must not be writable by posting its key, a number must land inside its bounds however it
  was typed, and a select must refuse a value that is not on its list.

  See `MishkaCmsCore.Settings.define/3` and `MishkaCmsCore.Settings.cast/2`.
  """
  alias MishkaCmsCore.Settings

  @category "security"

  @doc "The tab these settings live on, so a test does not have to hardcode it twice."
  def category, do: @category

  def definitions do
    [
      Settings.define("locked.fingerprint", :string,
        default: "do-not-touch",
        category: @category,
        scope: :master,
        source: :extension,
        editable?: false,
        label: "Deployment fingerprint",
        description: "Written by the installer; shown here for reference only."
      ),
      Settings.define("bounded.retention_days", :integer,
        default: 30,
        min: 1,
        max: 90,
        category: @category,
        scope: :master,
        source: :extension,
        label: "Retention (days)"
      ),
      Settings.define("choice.level", :select,
        default: "standard",
        options: ["standard", "strict"],
        category: @category,
        scope: :master,
        source: :extension,
        label: "Enforcement level"
      )
    ]
  end
end
