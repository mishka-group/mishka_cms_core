# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.HeadCodeItems do
  @moduledoc """
  Test plugin for `runtime:page:head`: adds a verification tag of its own and a tag the rules
  refuse, proving an extension reaches a page's head through the same path and the same rules as a
  site's entries.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:page:head"

  @impl true
  def call(%{items: items} = entry) do
    {:reply,
     %{
       entry
       | items:
           items ++
             [
               %{
                 tag: "meta",
                 attrs: [{"name", "extension-verify"}, {"content", "x"}],
                 content: nil
               },
               %{tag: "iframe", attrs: [{"src", "https://x.example"}], content: nil}
             ]
     }}
  end
end
