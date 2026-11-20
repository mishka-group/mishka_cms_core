# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.CreditedMenu do
  @moduledoc """
  Test plugin: two entries of the extension `:mishka_probe_credit`. The first names a credit, the
  second is a page of the extension and declares `credit_footer: false`, so every page of the
  extension draws no "Powered by" line; a third extension's entry names a credit and keeps it.
  """
  use MishkaInstaller.Event.Hook, event: "sidebar:menus"

  alias MishkaCmsCore.Sidebar.Item

  @doc "The module of the entry that names the credit."
  def credited, do: MishkaCmsCore.Test.Plugins.CreditedMenu.Credited

  @doc "The module of a page of the extension that draws no footer."
  def silent, do: MishkaCmsCore.Test.Plugins.CreditedMenu.Silent

  @doc "The module of a page of an extension that keeps its footer."
  def kept, do: MishkaCmsCore.Test.Plugins.CreditedMenu.Kept

  @impl true
  def call(%{items: items} = data) do
    mine = [
      Item.new!(%{
        key: "probe.credit",
        label: "Probe credit",
        path: "/admin/dashboard/probe-credit",
        extension: :mishka_probe_credit,
        module: credited(),
        credit_name: "Probe",
        credit_url: "https://example.test/probe",
        credit_footer: false,
        order: 16
      }),
      Item.new!(%{
        key: "probe.credit.page",
        label: "Probe page",
        path: "/admin/dashboard/probe-credit/page",
        extension: :mishka_probe_credit,
        module: silent(),
        order: 17
      }),
      Item.new!(%{
        key: "probe.kept",
        label: "Probe kept",
        path: "/admin/dashboard/probe-kept",
        extension: :mishka_probe_kept,
        module: kept(),
        credit_name: "Kept",
        credit_url: "https://example.test/kept",
        order: 18
      })
    ]

    {:reply, %{data | items: items ++ mine}}
  end
end
