# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Settings.ExtensionSettingsTest do
  @moduledoc """
  Real-world test: the Blog and Document extensions register their own configuration through the
  mishka_installer `settings:register` hook (two example plugins in `test/support/plugins`), the
  registry composes + seeds the defaults, and each extension then reads its config from RAM —
  including after an admin edits a value. No mocks: real plugin registration, real hook chain, real
  durable store + ETS cache.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.Plugins.{BlogSettingsPlugin, DocumentSettingsPlugin}
  alias MishkaInstaller.Event.{Event, EventHandler}

  @plugins [BlogSettingsPlugin, DocumentSettingsPlugin]

  setup do
    # Start from a clean cache so a sibling test's write (process-global ETS, not sandboxed) doesn't
    # make `load_definitions/0`'s "seed if missing" skip a default and leak a stale value into this test.
    SettingsState.refresh()

    Enum.each(@plugins, fn plugin ->
      {:ok, _} =
        Event.write(%{
          name: plugin,
          event: "settings:register",
          extension: :mishka_installer,
          status: :started
        })
    end)

    :ok = EventHandler.do_compile("settings:register", :start, false)
    Settings.load_definitions()

    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      Enum.each(@plugins, &Event.unregister(:name, &1, false))
      :persistent_term.erase({Settings, :definitions})
      SettingsState.restore(snapshot)
    end)

    :ok
  end

  test "both extensions register their settings, composed into the registry + their own tabs" do
    keys = Settings.definitions() |> Enum.map(& &1.key) |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new(["blog.posts_per_page", "blog.allow_comments", "blog.moderate_comments"]),
             keys
           )

    assert MapSet.subset?(
             MapSet.new([
               "document.default_format",
               "document.versions_to_keep",
               "document.public_by_default"
             ]),
             keys
           )

    assert "blog" in Settings.categories()
    assert "document" in Settings.categories()
    assert Settings.definition("blog.posts_per_page").source == :extension
    assert Settings.definition("document.default_format").type == :select
  end

  test "each extension reads its own config from RAM with the seeded defaults" do
    assert Settings.get("blog.posts_per_page", 10) == 10
    assert Settings.get("blog.allow_comments") == true
    assert Settings.get("document.default_format") == "markdown"
    assert Settings.get("document.versions_to_keep") == 20
  end

  test "an admin changes an extension setting and the extension immediately reads the new value" do
    assert Settings.get("blog.posts_per_page") == 10

    # an admin edits it (what the settings page will do)
    {:ok, _} = Settings.put("blog.posts_per_page", 25, category: "blog", source: :extension)

    # the blog extension reads the new value straight from RAM — no restart
    assert Settings.get("blog.posts_per_page") == 25
  end
end
