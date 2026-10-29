# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory do
  @moduledoc """
  Detaches a deleted draft's editing history from it, so the rows survive and join the live
  record's own timeline.

  One plugin per destroy action of the three draft resources, each on the announcement
  `MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook` fires after the destroy commits:
  `cms_core:page_draft:after_destroy` and `cms_core:page_draft:after_master_destroy`, and the same
  two for `layout_draft` and `error_page_draft`. A master's delete runs the `master_destroy` twin,
  which fires its own event, so both are listened on.

  ## Why this is not a foreign key

  It was one. `MishkaCmsCore.Runtime.PageBuilderEvent.draft_id` was a `belongs_to` to
  `MishkaCmsCore.Runtime.PageDraft` with `on_delete: :nilify`, which did exactly this job — for
  pages. But `source_type` names all four editable kinds and three of them keep their drafts in
  tables of their own, so a change made on a layout's or an error page's draft violated that one key
  and the row was refused: the History sheet was simply empty for those two sections.

  A single key cannot name three tables, so the column became a plain id and the nilify moved to
  the draft resources' own destroy — the same level the constraint was at, rather than any one
  caller. That matters because a draft is deleted from several places: the picker's Delete goes
  through the resource's own destroy, publishing spends the draft through
  `MishkaCmsCore.Runtime.PageBuilder.Drafts.discard/3`, and the twenty-draft sweep prunes through
  `prune/3`. Only the resource sees all of them, and its announcements are how the editor hears of
  each without the drafts naming the editor.

  ## Best effort, deliberately

  The release runs after the delete has committed and never undoes it: a draft the author asked to
  delete must go even if its history could not be released. A row left pointing at a draft that no
  longer exists is invisible rather than wrong — no read names a dead branch — so a failure is
  logged and the record is handed back as it came. It is never raised: a plugin that raises is
  skipped by the event, and the reason would be lost.
  """

  require Ash.Query
  require Logger

  alias MishkaCmsCore.Runtime.PageBuilderEvent

  @doc """
  Turns the module into the plugin on `event`, releasing the history of the draft it announces.

      use MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory,
        event: PluginHook.event_name(MishkaCmsCore.Runtime.PageDraft, :destroy)
  """
  defmacro __using__(opts) do
    event = Keyword.fetch!(opts, :event)

    quote do
      use MishkaInstaller.Event.Hook, event: unquote(event), initial: %{priority: 50}

      @impl true
      def call(%{id: draft_id} = draft, meta) do
        unquote(__MODULE__).release(draft_id, meta[:actor])
        {:reply, draft}
      end

      def call(draft, _meta), do: {:reply, draft}
    end
  end

  @doc """
  Sets `draft_id` to `nil` on every history row recorded on `draft_id`, as `actor`. Always `:ok`;
  a failure is logged.
  """
  @spec release(String.t(), map() | nil) :: :ok
  def release(draft_id, actor) do
    PageBuilderEvent
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(draft_id == ^draft_id)
    |> Ash.bulk_update(:release_draft, %{},
      authorize?: false,
      return_errors?: true,
      actor: actor
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> refused(draft_id, errors)
    end
  rescue
    error -> refused(draft_id, error)
  end

  defp refused(draft_id, reason) do
    Logger.warning(
      "[ReleaseDraftHistory] the history of draft #{draft_id} was not released: " <>
        inspect(reason)
    )

    :ok
  end
end

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.PageDraftDestroy do
  @moduledoc "Releases the history of a page draft a site admin deletes."

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory,
    event: PluginHook.event_name(MishkaCmsCore.Runtime.PageDraft, :destroy)
end

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.PageDraftMasterDestroy do
  @moduledoc "Releases the history of a page draft a master deletes."

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory,
    event: PluginHook.event_name(MishkaCmsCore.Runtime.PageDraft, :master_destroy)
end

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.LayoutDraftDestroy do
  @moduledoc "Releases the history of a layout draft a site admin deletes."

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory,
    event: PluginHook.event_name(MishkaCmsCore.Runtime.LayoutDraft, :destroy)
end

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.LayoutDraftMasterDestroy do
  @moduledoc "Releases the history of a layout draft a master deletes."

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory,
    event: PluginHook.event_name(MishkaCmsCore.Runtime.LayoutDraft, :master_destroy)
end

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.ErrorPageDraftDestroy do
  @moduledoc "Releases the history of an error-page draft a site admin deletes."

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory,
    event: PluginHook.event_name(MishkaCmsCore.Runtime.ErrorPageDraft, :destroy)
end

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory.ErrorPageDraftMasterDestroy do
  @moduledoc "Releases the history of an error-page draft a master deletes."

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaCmsCore.Runtime.PageBuilder.Plugins.ReleaseDraftHistory,
    event: PluginHook.event_name(MishkaCmsCore.Runtime.ErrorPageDraft, :master_destroy)
end
