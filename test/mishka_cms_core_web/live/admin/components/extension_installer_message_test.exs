# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Web.ExtensionInstallerMessageTest do
  @moduledoc """
  What the flash says after an extension's Set up (`ExtensionInstallerPanel.message/2`) on an older
  install: the pages nobody edited, now in the new design, are counted as brought up rather than
  left alone, and the components a site edited are named as waiting on their card.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel

  # A page already there, at its own path: what a run repeated reports in `skipped_pages`.
  defp there(path), do: %{path: path, fields: [path: path], ours?: true}

  test "a page an earlier release wrote and nobody edited is brought up, not left alone" do
    report = %{
      skipped_pages: [there("/:lang/blog"), there("/:lang/blog/:slug"), there("/:lang/blog/tags")],
      upgraded_pages: ["/:lang/blog", "/:lang/blog/:slug"],
      upgraded_components: ["blog-post-card"],
      components_waiting: []
    }

    message = ExtensionInstallerPanel.message(report, "blog")

    assert message =~ "2 pages nobody edited now have the new design."
    assert message =~ "1 component nobody edited is up to date."
    assert message =~ "1 page already there, left alone."
    refute message =~ "keep their earlier version"
  end

  test "an edited component is named as waiting on its card" do
    report = %{skipped_pages: [], components_waiting: ["blog-post-card", "blog-term-row"]}

    assert ExtensionInstallerPanel.message(report, "blog") =~
             "2 components keep their earlier version; update them from their components card."
  end

  test "a report from before the upgrade keys reads as it did" do
    report = %{skipped_pages: [there("/:lang/blog")]}

    assert ExtensionInstallerPanel.message(report, "blog") ==
             "This site already has everything the blog ships. Nothing to add. " <>
               "1 page already there, left alone."
  end
end
