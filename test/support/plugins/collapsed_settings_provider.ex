# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.CollapsedSettingsProvider do
  @moduledoc """
  Example provider: an extension whose optional settings sit in a collapsed group (`collapsed: true`)
  of its own tab, every one with a default of its own — a select, a switch, a number and a secret —
  and a plain group beside it that stays a heading.

  The accordion opens for a value other than the setting's default, so these are what proves the
  comparison is with the default and not with "empty". See `MishkaCmsCore.Settings.define/3`.
  """
  alias MishkaCmsCore.Settings

  @category "tuning"

  @doc "The tab these settings live on."
  def category, do: @category

  def definitions do
    [
      Settings.define("tuning.mode", :select,
        default: "standard",
        options: ["standard", "strict"],
        category: @category,
        group: "Advanced",
        collapsed: true,
        scope: :master,
        source: :extension,
        label: "Mode"
      ),
      Settings.define("tuning.verbose", :boolean,
        default: false,
        category: @category,
        group: "Advanced",
        scope: :master,
        source: :extension,
        label: "Verbose"
      ),
      Settings.define("tuning.limit", :integer,
        default: 10,
        category: @category,
        group: "Advanced",
        scope: :master,
        source: :extension,
        label: "Limit"
      ),
      Settings.define("tuning.token", :secret,
        category: @category,
        group: "Advanced",
        scope: :master,
        source: :extension,
        label: "Token"
      ),
      Settings.define("tuning.label", :string,
        default: "",
        category: @category,
        group: "Plain",
        scope: :master,
        source: :extension,
        label: "Label"
      ),
      Settings.define("tuning.alone", :string,
        default: "",
        category: @category,
        collapsed: true,
        scope: :master,
        source: :extension,
        label: "Alone"
      )
    ]
  end
end
