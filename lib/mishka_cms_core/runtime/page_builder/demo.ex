# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Demo do
  @moduledoc """
  Sample content for the editor's Assistant thread and its audit list, so those panels can be judged
  before there is anything real in them.

  A freshly opened page has no conversation and no findings, which is correct and also means the
  rails are empty rectangles: nobody can tell whether the layout and the plain-language notes look
  right. These are the prototype's own entries, in the same shapes the real ones use.

  The Record history sample is gone, because the record is real now: it is a log in the database,
  read by `MishkaCmsCoreWeb.Templates.HistoryTimeline`. Sample rows there would have been indistinguishable from somebody's actual work. `MishkaCmsCore.Dev.HistorySeeds` fills a page with every
  state the timeline draws when a populated one is wanted.

  **This is scaffolding.** It is off unless `:builder_demo_data` is set, it never replaces real
  content — the moment a session has one edit or one message, its own data is what shows — and every
  entry is marked `demo?: true` so nothing downstream can mistake it for a record. Delete this module
  and its remaining call sites in `Panels` when the real things arrive.

  While any of it is shown, the Assistant and Audit tabs say so in a roadmap notice, and each sample
  finding carries a Sample badge and a disabled Fix.

      config :mishka_cms_core, builder_demo_data: false

  See `MishkaCmsCoreWeb.Live.Admin.Builder.Panels` (`assistant/1`).
  """

  @doc "Whether the sample content is switched on for this environment."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:mishka_cms_core, :builder_demo_data, false) == true

  @messages [
    %{
      role: :assistant,
      text:
        "I can edit this page for you — describe a change, or select an element and use “Ask AI” " <>
          "to scope it.",
      scope: nil,
      plain: nil,
      ops: []
    },
    %{
      role: :user,
      text: "Make the header sticky and reduce its height a bit",
      scope: "<header>",
      plain: nil,
      ops: [],
      author: "Shahryar Tavakkoli"
    },
    %{
      role: :assistant,
      text: "Done — set position:sticky with top:0 on <header> and reduced padding to 14px 28px.",
      scope: "<header>",
      plain: "Made your header stay at the top when people scroll, and made it slightly shorter.",
      ops: [],
      revision: "r14",
      revision_note: "2 properties · header"
    },
    %{
      role: :user,
      text: "Add a testimonials section under the hero",
      scope: nil,
      plain: nil,
      ops: [],
      author: "Shahryar Tavakkoli"
    },
    %{
      role: :assistant,
      text:
        "Inserted a 3-column testimonials block after <section class=\"hero\"> with placeholder quotes.",
      scope: "section.hero",
      plain: "Added a row of three customer quotes just below your hero image.",
      ops: [],
      revision: "r15",
      revision_note: "1 block added · 18 lines"
    }
  ]

  # Real `Comment` structs, so the Review sheet, its filter and the top bar's badge all treat them
  # exactly as they treat a note someone typed — including Resolve.

  # The prototype's audit lines that this editor cannot yet measure for itself.
  #
  # TODO: contrast needs the RENDERED colours — the computed foreground and background of every text
  # run after the site's stylesheet and the runtime tokens have been applied — which lives in the
  # canvas document, not in the tree. Wire it to a real check (canvas-side sampling pushed back to
  # the rail) and delete this entry; everything else in the Audit rail is already measured.
  @audit [
    %{
      node_id: nil,
      group: :accessibility,
      severity: :warning,
      rule: "contrast",
      message: "Low contrast on muted text",
      detail: "3.1:1 — needs 4.5:1 for body copy."
    }
  ]

  @doc """
  Audit lines the real checks do not produce yet, or `[]` when the flag is off.

  Every one of these is a placeholder for a check that should exist; see the TODO above.
  """
  @spec audit_findings() :: [map()]
  def audit_findings, do: mark(@audit)

  @doc "The sample conversation, or `[]` when the flag is off."
  @spec messages() :: [map()]
  def messages, do: mark(@messages)

  defp mark(entries), do: Enum.map(marked(enabled?(), entries), &Map.put(&1, :demo?, true))

  defp marked(true, entries), do: entries
  defp marked(false, _entries), do: []
end
