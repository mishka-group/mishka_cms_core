defmodule MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore do
  @moduledoc """
  Refuses to restore a translation unless its master is live once the restore is done.

  The other half of `MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion`. That
  one keeps a master from going while a live translation points at it; this one keeps a translation
  from coming back to a master that is archived or gone. Either way round, the rule is the same: a
  live row's master is a live row too, so every edition of a document is reachable from the list —
  the admin tables list masters and reach a translation through its master's chips, and a restored
  translation whose master is still archived has neither a row nor a chip of its own.

  It queries `changeset.resource`, so it guards every resource carrying the pattern —
  `MishkaCmsCore.Runtime.Page`, `MishkaBlog.Collection`, `MishkaDocument.Workspace`. Put it on both
  restoring actions:

      update :unarchive do
        change MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore
      end

      update :master_unarchive do
        change MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore
      end

  ## Why a change that checks after the write, and not a validation

  Because the archive lists a master beside its archived editions, and restoring the group is one
  selection over all of them. A validation answers before anything is written, so every translation
  in that selection would be told its master is archived — the master's own restore is in the same
  batch, still ahead of it. Checking after the write sees the batch as the reader meant it: the
  master is back, and the translations restored with it land in a group that holds. A selection that
  leaves the master behind still refuses, and the refusal rolls the write back.

  A resource written a row at a time has no batch behind it — a manual action, as
  `MishkaDocument.Workspace`'s are — so `MishkaCmsCore.LanguageEditions.BulkActionHandler` hands the
  archive's masters over first and this check finds the master already restored.

  ## What it refuses

  Whatever the read cannot account for. A master that is archived says so and asks for it first; a
  master no row holds any more cannot be asked for at all, so that edition can only be deleted; and a
  read that fails refuses too, because a translation restored on a failed check is the orphan this
  exists to prevent.

  ## The refusal

  An `Ash.Error.Changes.InvalidAttribute` on `:language_group_id` whose message is `message/2`: the
  translation's language, its original's, and what to do. The API returns that message as it is.
  It is written in the Gettext locale of the process the action runs in, `errors` domain, since the
  language names inside it are translated too; a request with no locale reads it in English.
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &restored/2)
  end

  # A RECORD WITH NO GROUP, OR ONE OF ITS OWN ID, IS A MASTER: it is what the rest are restored under,
  # and `MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId` gives one to a row archived
  # before its resource had the column.
  defp restored(_changeset, %{id: id, language_group_id: group} = record)
       when group == id or is_nil(group),
       do: {:ok, record}

  defp restored(%{resource: resource}, record) do
    case live_master?(resource, record) do
      {:ok, true} -> {:ok, record}
      {:ok, false} -> {:error, refusal(resource, record)}
      {:error, _reason} -> {:error, error(record, :unchecked)}
    end
  end

  defp refusal(resource, record) do
    case archived_master(resource, record) do
      {:ok, %{language: language}} -> error(record, {:archived, language})
      {:ok, nil} -> error(record, :deleted)
      {:error, _reason} -> error(record, :unchecked)
    end
  end

  # The primary read holds the live rows — every resource here filters the archived ones out of it —
  # and `:archived` holds only those, so between them they say which of the two refusals it is.
  defp live_master?(resource, %{language_group_id: group, site_id: site}) do
    resource
    |> Ash.Query.filter(id == ^group)
    |> Ash.exists(tenant: site, authorize?: false)
  end

  defp archived_master(resource, %{language_group_id: group, site_id: site}) do
    resource
    |> Ash.Query.for_read(:archived, %{}, tenant: site, authorize?: false)
    |> Ash.Query.filter(id == ^group)
    |> Ash.Query.select([:language])
    |> Ash.read_one(authorize?: false)
  end

  @doc """
  What refusing to restore a translation says: its own language, its original's, and what to do.

      message("fa", {:archived, "en"})
      #=> "This is the Persian translation. Its original English version is archived, so it can't be
      #    restored yet. Restore the original first, then this one."

      message("fa", :deleted)
      #=> "This is the Persian translation. Its original version has been deleted for good, so it
      #    can't be restored. It can only be deleted for good."
  """
  @spec message(
          String.t() | atom() | nil,
          {:archived, String.t() | atom() | nil} | :deleted | :unchecked
        ) ::
          String.t()
  def message(language, {:archived, original}) do
    translation(language) <> " " <> archived(Languages.name(original))
  end

  def message(language, :deleted) do
    translation(language) <>
      " " <>
      dgettext(
        "errors",
        "Its original version has been deleted for good, so it can't be restored. It can only be deleted for good."
      )
  end

  def message(language, :unchecked) do
    translation(language) <>
      " " <>
      dgettext(
        "errors",
        "Its original version could not be checked just now, so it can't be restored yet. Try again in a moment."
      )
  end

  defp translation(language) do
    case Languages.name(language) do
      nil -> dgettext("errors", "This is a translation.")
      name -> dgettext("errors", "This is the %{language} translation.", language: name)
    end
  end

  defp archived(nil) do
    dgettext(
      "errors",
      "Its original version is archived, so it can't be restored yet. Restore the original first, then this one."
    )
  end

  defp archived(name) do
    dgettext(
      "errors",
      "Its original %{language} version is archived, so it can't be restored yet. Restore the original first, then this one.",
      language: name
    )
  end

  defp error(record, why) do
    Ash.Error.Changes.InvalidAttribute.exception(
      field: :language_group_id,
      message: message(Map.get(record, :language), why)
    )
  end
end
