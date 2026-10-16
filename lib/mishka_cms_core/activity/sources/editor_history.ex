# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.EditorHistory do
  @moduledoc """
  Activity source for the visual editor's own record — every change somebody made to a page, layout,
  component or error page in the page builder, tagged `badge_label: "EDITOR"`.

  ## Why it needs a source of its own

  No other adapter can see these. `MishkaCmsCore.Runtime.PageBuilderEvent` is not AshPaperTrail
  versioned, is not an AshEvents log and is not an Oban job — it is a lean append-only table the
  editor writes as somebody works, which is exactly why the timeline in the editor is fast. That
  makes it invisible to the global feed unless something goes and reads it, which is this.

  One store, two surfaces: the sheet inside the editor answers "what happened to THIS document",
  and the feed answers "what happened across the site". Neither is a copy of the other.

  ## History only, and deliberately

  The resource broadcasts nothing — `pub_sub` is off on it, because a row is written on every
  settled change and re-reading a table for everybody on every keystroke is the noise the whole
  design avoids. So `topics/1` is empty and `handles?/1` is always false: this contributes to the
  merged history read and never to the live tail. A change appears in the feed on the next read,
  which for a record of what happened is the right trade.

  Two actions, in the feed's own vocabulary: **publish** for a publish, **update** for every other
  change — because the feed has one shared set of action words that every source reports in, and
  widening it for this one would change how the others render. Which change it was is in the message
  beside it, in the same words the editor's own timeline uses: "Set gap (base) — <nav>".

  See `MishkaCmsCore.Activity.Behaviours.Source` and `MishkaCmsCore.Activity.Query` (the DB-merge
  branch, which owns the SQL).
  """

  @behaviour MishkaCmsCore.Activity.Behaviours.Source

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Activity.Helpers
  alias MishkaCmsCore.Runtime.{Component, ErrorPage, Layout, Page}

  @label gettext_noop("Editor")

  # What the row's anchor points at, so a resource-scoped feed can ask for one document's changes.
  # Keyed by the module name the merged row reports, which is what every other source reports too.
  @scopes %{
    to_string(Page) => gettext_noop("Page"),
    to_string(Layout) => gettext_noop("Layout"),
    to_string(Component) => gettext_noop("Component"),
    to_string(ErrorPage) => gettext_noop("Error page")
  }

  @doc "The resources whose feeds this source contributes to."
  @spec scopes() :: %{String.t() => String.t()}
  def scopes, do: @scopes

  @impl true
  def topics(_scope), do: []

  @impl true
  def handles?(_broadcast), do: false

  @impl true
  def to_entry(_broadcast), do: nil

  @impl true
  def initial_fetch(_scope, _limit), do: []

  @doc """
  Turns one merged row into a feed entry.

  Called by `MishkaCmsCore.Activity.Query` for rows its `editor` branch produced.
  """
  @spec entry_from_row(map()) :: map()
  def entry_from_row(row) do
    payload = row["payload"] || %{}
    action = Helpers.action_atom(row["action"])

    %{
      # The EVENT's id, not the document's — `source_id` names the live record (every other source
      # reports it that way, and a resource-scoped feed filters on it), so the row's own identity has
      # to come from `event_id` or every change to one page would collapse onto a single entry.
      id: "editor-#{row["event_id"]}",
      resource_label: label_for(row["resource"]),
      badge_label: gettext("EDITOR"),
      # `#4f4bcc` — the colour the editor's own sheet draws a change in (`HistoryTimeline`), so one
      # change is the same colour wherever somebody meets it.
      badge_tone: :violet,
      action: action,
      severity: :info,
      tone: Helpers.tone_for(action),
      inserted_at: Helpers.to_datetime(row["inserted_at"]),
      source_id: row["source_id"],
      site_id: row["site_id"],
      user_id: row["user_id"],
      message: message(payload)
    }
  end

  # "Set gap (base) — <nav>", which is what the editor's own timeline says about the same change.
  defp message(%{"label" => label, "target" => target}) when is_binary(target) and target != "",
    do: gettext("%{label} — %{target}", label: label, target: target)

  defp message(%{"label" => label}) when is_binary(label), do: label
  defp message(_payload), do: gettext("A change in the editor")

  defp label_for(resource) do
    case Map.get(@scopes, to_string(resource)) do
      nil ->
        Helpers.translate(@label)

      name ->
        gettext("%{editor} · %{name}",
          editor: Helpers.translate(@label),
          name: Helpers.translate(name)
        )
    end
  end
end
